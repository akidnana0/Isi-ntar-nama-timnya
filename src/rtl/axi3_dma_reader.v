// ============================================================================
// axi3_dma_reader.v : FSM AXI3 DMA READER (pull mode) - INTERLEAVED, multi-context
//
// Walks the job descriptor queue in HPS DDR3 (JOB_BASE) and streams documents
// into the Block Splitter as AXI4-Stream (64-bit, TKEEP, TLAST, TUSER, TCTX).
//
// Up to `max_ctx` documents are open at once (one per context, max_ctx = number
// of enabled cores, captured at START). Contexts are served round-robin, ONE
// SHA-512 BLOCK (16 beats = 128 B) PER TURN, so consecutive blocks in the stream
// belong to different documents and all cores can work in parallel.
// (v1 streamed whole documents back-to-back -> head-of-line blocking: a
//  multi-block document kept every other core idle.)
//
// Descriptor (16 bytes = 2 x 64-bit beats, little-endian):
//   word0 = { job_id[15:0], 16'b0, doc_len_bytes[31:0] }
//   word1 = { 32'b0, doc_addr[31:0] }          (8-byte aligned)
//
// FSM: IDLE -> SCHED -+-> DESC_AR -> DESC_R -> DESC_LD -+-> SCHED
//                     |                                 \-> EMPTY -> SCHED
//                     +-> DATA_AR -> DATA_R -> SCHED (or DATA_AR on 4 KB split)
//      rresp != OKAY -> DRAIN (accept the rest of the burst) -> ERR -> IDLE
// Bursts: <= 16 beats, never cross a 4 KB boundary (AXI rule).
// ============================================================================
module axi3_dma_reader #(
    parameter NCTX = 16,                // physical contexts (>= max_ctx used)
    parameter CW   = 4                  // context index width
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          start,          // 1-cycle pulse from system FSM
    input  wire [31:0]   job_base,
    input  wire [31:0]   job_count,      // number of descriptors to process
    input  wire [CW:0]   max_ctx,        // 1..NCTX, sampled on start
    input  wire          halt,           // RESET/FLUSH requested: finish/drain the
                                         // current burst, issue nothing new, go IDLE

    // AXI3 read master
    output wire [11:0]   m_axi_arid,
    output wire [31:0]   m_axi_araddr,
    output wire [3:0]    m_axi_arlen,
    output wire [2:0]    m_axi_arsize,
    output wire [1:0]    m_axi_arburst,
    output wire          m_axi_arvalid,
    input  wire          m_axi_arready,
    input  wire [11:0]   m_axi_rid,
    input  wire [63:0]   m_axi_rdata,
    input  wire [1:0]    m_axi_rresp,
    input  wire          m_axi_rlast,
    input  wire          m_axi_rvalid,
    output wire          m_axi_rready,

    // AXI4-Stream master
    output wire [63:0]   m_axis_tdata,
    output wire          m_axis_tvalid,
    input  wire          m_axis_tready,
    output wire          m_axis_tlast,
    output wire [7:0]    m_axis_tkeep,
    output wire [15:0]   m_axis_tuser,
    output wire [CW-1:0] m_axis_tctx,

    output wire          busy,
    output wire          err_pulse
);
    localparam R_IDLE=4'd0, R_SCHED=4'd1, R_DESC_AR=4'd2, R_DESC_R=4'd3, R_DESC_LD=4'd4,
               R_EMPTY=4'd5, R_DATA_AR=4'd6, R_DATA_R=4'd7, R_DRAIN=4'd8, R_ERR=4'd9;

    reg [3:0]    st;
    reg [31:0]   jobs_left, desc_addr;
    reg          desc_beat;
    reg [63:0]   w0, w1;
    reg [CW:0]   nctx;                   // contexts in use this run
    reg [CW-1:0] cur, rr;
    reg [4:0]    turn_left;              // beats left in this context's turn (<=16)

    // per-context state
    reg [NCTX-1:0] c_act;
    reg [15:0]     c_id    [0:NCTX-1];
    reg [31:0]     c_addr  [0:NCTX-1];
    reg [31:0]     c_beats [0:NCTX-1];   // beats left in the document
    reg [2:0]      c_tail  [0:NCTX-1];   // doc_len[2:0]

    // ---- scheduling: free context (for a new descriptor) / next active ----
    reg          f_found, a_found;
    reg [CW-1:0] f_idx, a_idx;
    integer      i, k;
    always @* begin
        f_found = 1'b0; f_idx = {CW{1'b0}};
        a_found = 1'b0; a_idx = {CW{1'b0}};
        for (i = 0; i < NCTX; i = i + 1) begin
            if (!f_found && (i < nctx) && !c_act[i]) begin f_found = 1'b1; f_idx = i[CW-1:0]; end
            k = rr + i; if (k >= NCTX) k = k - NCTX;
            if (!a_found && (k < nctx) && c_act[k])  begin a_found = 1'b1; a_idx = k[CW-1:0]; end
        end
    end

    // ---- burst sizing: min(turn_left, beats to next 4 KB boundary) ----------
    wire [31:0] cur_addr  = c_addr[cur];
    wire [31:0] cur_beats = c_beats[cur];
    wire [9:0]  b4k_beats = (13'd4096 - {1'b0, cur_addr[11:0]}) >> 3;   // 1..512
    wire [4:0]  burst_sz  = ({5'd0, turn_left} <= b4k_beats) ? turn_left : b4k_beats[4:0];

    wire        last_doc_beat = (cur_beats == 32'd1);
    wire [3:0]  last_n        = (c_tail[cur] == 3'd0) ? 4'd8 : {1'b0, c_tail[cur]};
    wire [8:0]  keep_ext      = (9'd1 << last_n) - 9'd1;

    wire        r_fire = m_axi_rvalid & m_axi_rready;
    wire        rbad   = r_fire & (m_axi_rresp != 2'b00);
    wire [CW-1:0] cur_nx = (cur == nctx - 1'b1) ? {CW{1'b0}} : cur + 1'b1;

    integer q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= R_IDLE; jobs_left <= 0; desc_addr <= 0; desc_beat <= 0;
            w0 <= 0; w1 <= 0; nctx <= 1; cur <= 0; rr <= 0; turn_left <= 0;
            c_act <= {NCTX{1'b0}};
            for (q = 0; q < NCTX; q = q + 1) begin
                c_id[q] <= 0; c_addr[q] <= 0; c_beats[q] <= 0; c_tail[q] <= 0;
            end
        end else begin
            case (st)
            R_IDLE: if (start && job_count != 0) begin
                jobs_left <= job_count;
                desc_addr <= job_base;
                nctx      <= (max_ctx == 0) ? 1 : (max_ctx > NCTX) ? NCTX[CW:0] : max_ctx;
                rr        <= 0;
                c_act     <= {NCTX{1'b0}};
                st        <= R_SCHED;
            end

            R_SCHED:
                if (halt) st <= R_IDLE;
                else if (jobs_left != 0 && f_found) begin        // open a new document
                    cur <= f_idx; st <= R_DESC_AR;
                end else if (a_found) begin                 // one block for this doc
                    cur       <= a_idx;
                    turn_left <= (c_beats[a_idx] >= 32'd16) ? 5'd16 : c_beats[a_idx][4:0];
                    st        <= R_DATA_AR;
                end else if (jobs_left == 0)
                    st <= R_IDLE;                           // everything streamed

            R_DESC_AR: if (m_axi_arready) begin desc_beat <= 1'b0; st <= R_DESC_R; end

            R_DESC_R: if (r_fire) begin
                if (halt)            begin if (m_axi_rlast) st <= R_IDLE; end
                else if (rbad)            st <= m_axi_rlast ? R_ERR : R_DRAIN;
                else if (!desc_beat) begin w0 <= m_axi_rdata; desc_beat <= 1'b1; end
                else                 begin w1 <= m_axi_rdata; st <= R_DESC_LD; end
            end

            R_DESC_LD: if (halt) st <= R_IDLE; else begin
                c_id[cur]    <= w0[63:48];
                c_addr[cur]  <= w1[31:0];
                c_beats[cur] <= (w0[31:0] + 32'd7) >> 3;
                c_tail[cur]  <= w0[2:0];
                jobs_left    <= jobs_left - 32'd1;
                desc_addr    <= desc_addr + 32'd16;
                if (w0[31:0] == 32'd0) st <= R_EMPTY;
                else begin c_act[cur] <= 1'b1; st <= R_SCHED; end
            end

            R_EMPTY: if (halt) st <= R_IDLE; else if (m_axis_tready) st <= R_SCHED;

            R_DATA_AR: if (m_axi_arready) begin
                c_addr[cur] <= cur_addr + {22'd0, burst_sz, 3'b000};
                st          <= R_DATA_R;
            end

            R_DATA_R: if (r_fire) begin
                if (halt)      begin if (m_axi_rlast) st <= R_IDLE; end
                else if (rbad) st <= m_axi_rlast ? R_ERR : R_DRAIN;
                else begin
                    c_beats[cur] <= cur_beats - 32'd1;
                    turn_left    <= turn_left - 5'd1;
                    if (m_axi_rlast) begin
                        if (last_doc_beat) begin c_act[cur] <= 1'b0; rr <= cur_nx; st <= R_SCHED; end
                        else if (turn_left == 5'd1) begin           rr <= cur_nx; st <= R_SCHED; end
                        else st <= R_DATA_AR;                       // 4 KB split, same turn
                    end
                end
            end

            R_DRAIN: if (r_fire & m_axi_rlast) st <= R_ERR;   // never leave a burst half-read

            R_ERR: begin c_act <= {NCTX{1'b0}}; st <= R_IDLE; end
            default: st <= R_IDLE;
            endcase
        end

    // AXI read address channel
    assign m_axi_arid    = 12'd0;
    assign m_axi_arsize  = 3'd3;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = (st == R_DESC_AR) | (st == R_DATA_AR);
    assign m_axi_araddr  = (st == R_DESC_AR) ? desc_addr : cur_addr;
    assign m_axi_arlen   = (st == R_DESC_AR) ? 4'd1 : (burst_sz[3:0] - 4'd1);

    // data -> stream pass-through
    assign m_axi_rready  = (st == R_DESC_R) | (st == R_DRAIN) | ((st == R_DATA_R) & (m_axis_tready | halt));
    assign m_axis_tvalid = ~halt & (((st == R_DATA_R) & m_axi_rvalid & (m_axi_rresp == 2'b00)) | (st == R_EMPTY));
    assign m_axis_tdata  = (st == R_EMPTY) ? 64'd0 : m_axi_rdata;
    assign m_axis_tlast  = (st == R_EMPTY) | ((st == R_DATA_R) & last_doc_beat);
    assign m_axis_tkeep  = (st == R_EMPTY) ? 8'h00 : (last_doc_beat ? keep_ext[7:0] : 8'hFF);
    assign m_axis_tuser  = c_id[cur];
    assign m_axis_tctx   = cur;

    assign busy      = (st != R_IDLE);
    assign err_pulse = (st == R_ERR);
endmodule
