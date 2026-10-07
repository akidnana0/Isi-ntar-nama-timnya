// ============================================================================
// axi3_output_if.v : OUTPUT INTERFACE  (AXI4-Stream -> dual-clock FIFO -> AXI3 master)
//
//   TDATA(512)/TVALID/TLAST/TUSER(16) from Result Aggregator   (core_clk)
//   Adress_Out = m_axi_awaddr, Data_Out = m_axi_wdata, BRESP = m_axi_bresp
//
// Result packet in HPS DDR3 (one slot = 128 bytes, 9 x 64-bit beats used):
//   beat 0 : {48'b0, job_id}
//   beat 1..8 : digest[511:448] ... digest[63:0]   (SHA-512 big-endian word order)
// Slot address = RES_BASE + slot_idx*128, slot_idx wraps at RES_SLOTS
// (RES_SLOTS = 0 -> always slot 0). RES_BASE must be 128-byte aligned.
//
// AXI3 master FSM:  IDLE -> AW -> W (9 beats) -> B (wait BRESP) -> IDLE
// The next packet is only sent after BRESP of the previous one.
// ============================================================================
module axi3_output_if #(
    parameter FIFO_ADDR_W = 3
)(
    input  wire         core_clk,
    input  wire         core_rst_n,
    input  wire         h2f_axi_clk,
    input  wire         h2f_axi_rst_n,

    // AXI4-Stream slave (core_clk)
    input  wire [511:0] s_axis_tdata,
    input  wire         s_axis_tvalid,
    output wire         s_axis_tready,
    input  wire         s_axis_tlast,
    input  wire [15:0]  s_axis_tuser,

    // control (quasi-static, written before START)
    input  wire [31:0]  res_base,
    input  wire [31:0]  res_slots,

    // AXI3 master (write channels only)
    output wire [11:0]  m_axi_awid,
    output wire [31:0]  m_axi_awaddr,
    output wire [3:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [11:0]  m_axi_wid,
    output wire [63:0]  m_axi_wdata,
    output wire [7:0]   m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [11:0]  m_axi_bid,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,

    // status pulses (h2f_axi_clk domain)
    output wire         wr_done_pulse,   // packet written, BRESP OKAY
    output wire         wr_err_pulse     // BRESP != OKAY
);
    // ---------------- core_clk -> h2f_axi_clk FIFO ---------------------------
    wire         fifo_full, fifo_empty;
    wire [527:0] fifo_rdata;
    reg          pop;

    assign s_axis_tready = ~fifo_full;

    async_fifo #(.WIDTH(528), .ADDR_W(FIFO_ADDR_W)) u_fifo (
        .wclk (core_clk),    .wrst_n(core_rst_n),
        .winc (s_axis_tvalid & s_axis_tready),
        .wdata({s_axis_tuser, s_axis_tdata}),
        .wfull(fifo_full),
        .rclk (h2f_axi_clk), .rrst_n(h2f_axi_rst_n),
        .rinc (pop), .rdata(fifo_rdata), .rempty(fifo_empty)
    );

    // ---------------- AXI3 master FSM (h2f_axi_clk) --------------------------
    localparam O_IDLE = 2'd0, O_AW = 2'd1, O_W = 2'd2, O_B = 2'd3;

    reg [1:0]   st;
    reg [3:0]   beat;
    reg [511:0] dig;
    reg [15:0]  job;
    reg [15:0]  slot;

    always @* pop = (st == O_IDLE) & ~fifo_empty;

    wire [16:0] slot_inc  = {1'b0, slot} + 17'd1;
    wire        slot_wrap = (slot_inc >= {1'b0, res_slots[15:0]});

    always @(posedge h2f_axi_clk or negedge h2f_axi_rst_n)
        if (!h2f_axi_rst_n) begin
            st <= O_IDLE; beat <= 4'd0; dig <= 512'd0; job <= 16'd0; slot <= 16'd0;
        end else begin
            case (st)
            O_IDLE: if (~fifo_empty) begin
                dig  <= fifo_rdata[511:0];
                job  <= fifo_rdata[527:512];
                st   <= O_AW;
            end
            O_AW: if (m_axi_awready) begin
                beat <= 4'd0;
                st   <= O_W;
            end
            O_W: if (m_axi_wready) begin
                if (beat != 4'd0) dig <= {dig[447:0], 64'd0};
                if (beat == 4'd8) st <= O_B;
                else              beat <= beat + 4'd1;
            end
            O_B: if (m_axi_bvalid) begin
                if (m_axi_bresp == 2'b00)
                    slot <= slot_wrap ? 16'd0 : slot_inc[15:0];
                st <= O_IDLE;
            end
            endcase
        end

    assign m_axi_awid    = 12'd0;
    assign m_axi_awaddr  = res_base + {9'd0, slot, 7'd0};
    assign m_axi_awlen   = 4'd8;            // 9 beats
    assign m_axi_awsize  = 3'd3;            // 8 bytes
    assign m_axi_awburst = 2'b01;           // INCR
    assign m_axi_awvalid = (st == O_AW);
    assign m_axi_wid     = 12'd0;
    assign m_axi_wdata   = (beat == 4'd0) ? {48'd0, job} : dig[511:448];
    assign m_axi_wstrb   = 8'hFF;
    assign m_axi_wlast   = (beat == 4'd8);
    assign m_axi_wvalid  = (st == O_W);
    assign m_axi_bready  = (st == O_B);

    assign wr_done_pulse = (st == O_B) & m_axi_bvalid & (m_axi_bresp == 2'b00);
    assign wr_err_pulse  = (st == O_B) & m_axi_bvalid & (m_axi_bresp != 2'b00);
endmodule
