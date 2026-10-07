// ============================================================================
// axi3_dma_reader.v : FSM AXI3 DMA READER (pull mode)
//
// Walks the job descriptor queue in HPS DDR3 (JOB_BASE) and streams each
// document into the Block Splitter as AXI4-Stream (64-bit, TKEEP, TLAST, TUSER).
//
// Descriptor (16 bytes = 2 x 64-bit beats, little-endian):
//   word0 = { job_id[15:0], 16'b0, doc_len_bytes[31:0] }
//   word1 = { 32'b0, doc_addr[31:0] }          (8-byte aligned)
//
// FSM:  IDLE -> DESC_AR -> DESC_R -> CHECK -> DATA_AR -> DATA_R -> NEXT
//                                      \-> EMPTY (len = 0) -> NEXT
//       any rresp != OKAY -> ERR
// Bursts: <= 16 beats, never cross a 4 KB boundary (AXI rule).
// Runs in core_clk; the f2h/read bridge clock must be the same fabric clock.
// ============================================================================
module axi3_dma_reader (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,          // 1-cycle pulse from system FSM
    input  wire [31:0] job_base,
    input  wire [31:0] job_count,      // number of descriptors to process

    // AXI3 read master
    output wire [11:0] m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [3:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [11:0] m_axi_rid,
    input  wire [63:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    // AXI4-Stream master
    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [7:0]  m_axis_tkeep,
    output wire [15:0] m_axis_tuser,

    output wire        busy,
    output wire        err_pulse
);
    localparam R_IDLE=4'd0, R_DESC_AR=4'd1, R_DESC_R=4'd2, R_CHK=4'd3,
               R_DATA_AR=4'd4, R_DATA_R=4'd5, R_EMPTY=4'd6, R_NEXT=4'd7, R_ERR=4'd8;

    reg [3:0]  st;
    reg [31:0] jobs_left;
    reg [31:0] desc_addr;
    reg        desc_beat;
    reg [63:0] w0, w1;
    reg [15:0] job_id;
    reg [31:0] doc_len, doc_addr;
    reg [31:0] beats_left;
    reg [4:0]  cur_burst;       // beats in the burst currently being read

    // ---- burst sizing: min(16, beats_left, beats to next 4KB boundary) ------
    wire [9:0]  b4k_beats = (13'd4096 - {1'b0, doc_addr[11:0]}) >> 3;   // 1..512
    wire [4:0]  burst_sz  = (beats_left >= 32'd16 && b4k_beats >= 10'd16) ? 5'd16 :
                            ((beats_left < {22'd0, b4k_beats}) ? beats_left[4:0] : b4k_beats[4:0]);

    wire        last_doc_beat = (beats_left == 32'd1);
    wire [3:0]  last_n        = (doc_len[2:0] == 3'd0) ? 4'd8 : {1'b0, doc_len[2:0]};
    wire [8:0]  keep_ext      = (9'd1 << last_n) - 9'd1;
    wire [7:0]  keep_last     = keep_ext[7:0];

    wire        rbad = m_axi_rvalid & m_axi_rready & (m_axi_rresp != 2'b00);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= R_IDLE; jobs_left <= 0; desc_addr <= 0; desc_beat <= 0;
            w0 <= 0; w1 <= 0; job_id <= 0; doc_len <= 0; doc_addr <= 0;
            beats_left <= 0; cur_burst <= 0;
        end else begin
            case (st)
            R_IDLE: if (start && job_count != 0) begin
                jobs_left <= job_count;
                desc_addr <= job_base;
                st        <= R_DESC_AR;
            end

            R_DESC_AR: if (m_axi_arready) begin
                desc_beat <= 1'b0;
                st        <= R_DESC_R;
            end

            R_DESC_R: if (m_axi_rvalid) begin
                if (m_axi_rresp != 2'b00) st <= R_ERR;
                else if (!desc_beat) begin w0 <= m_axi_rdata; desc_beat <= 1'b1; end
                else begin w1 <= m_axi_rdata; st <= R_CHK; end
            end

            R_CHK: begin
                job_id     <= w0[63:48];
                doc_len    <= w0[31:0];
                doc_addr   <= w1[31:0];
                beats_left <= (w0[31:0] + 32'd7) >> 3;
                st         <= (w0[31:0] == 32'd0) ? R_EMPTY : R_DATA_AR;
            end

            R_DATA_AR: if (m_axi_arready) begin
                cur_burst <= burst_sz;
                doc_addr  <= doc_addr + {22'd0, burst_sz, 3'b000};
                st        <= R_DATA_R;
            end

            R_DATA_R: begin
                if (rbad) st <= R_ERR;
                else if (m_axi_rvalid & m_axi_rready) begin
                    beats_left <= beats_left - 32'd1;
                    if (m_axi_rlast)
                        st <= last_doc_beat ? R_NEXT : R_DATA_AR;
                end
            end

            R_EMPTY: if (m_axis_tready) st <= R_NEXT;

            R_NEXT: begin
                jobs_left <= jobs_left - 32'd1;
                desc_addr <= desc_addr + 32'd16;
                st        <= (jobs_left == 32'd1) ? R_IDLE : R_DESC_AR;
            end

            R_ERR: st <= R_IDLE;
            default: st <= R_IDLE;
            endcase
        end

    // AXI read address channel
    assign m_axi_arid    = 12'd0;
    assign m_axi_arsize  = 3'd3;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (st == R_DESC_AR) | (st == R_DATA_AR);
    assign m_axi_araddr  = (st == R_DESC_AR) ? desc_addr : doc_addr;
    assign m_axi_arlen   = (st == R_DESC_AR) ? 4'd1 : (burst_sz[3:0] - 4'd1);

    // data -> stream pass-through
    assign m_axi_rready  = (st == R_DESC_R) | ((st == R_DATA_R) & m_axis_tready);
    assign m_axis_tvalid = ((st == R_DATA_R) & m_axi_rvalid) | (st == R_EMPTY);
    assign m_axis_tdata  = (st == R_EMPTY) ? 64'd0 : m_axi_rdata;
    assign m_axis_tlast  = (st == R_EMPTY) | ((st == R_DATA_R) & last_doc_beat);
    assign m_axis_tkeep  = (st == R_EMPTY) ? 8'h00 : (last_doc_beat ? keep_last : 8'hFF);
    assign m_axis_tuser  = job_id;

    assign busy      = (st != R_IDLE);
    assign err_pulse = (st == R_ERR);
endmodule
