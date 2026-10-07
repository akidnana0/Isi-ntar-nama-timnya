// ============================================================================
// axi3_input_if.v : INPUT INTERFACE  (AXI3 slave  ->  dual-clock FIFO -> AXI4-Stream)
//
//   Adress_In  = s_axi_awaddr (32)     Data_In = s_axi_wdata (64)
//   BRESP      = s_axi_bresp  (2)      l3_main_clk handled inside the h2f bridge
//   TDATA/TVALID/TLAST/TUSER(+TKEEP)   -> to Block Splitter (core_clk domain)
//
// Sideband encoding (no extra registers needed):
//   * Job ID  = AWID (zero extended to 16 bit, TUSER)
//   * End-of-document = AWADDR[DOC_LAST_BIT] of the *last burst* of a document.
//                       TLAST = WLAST of that burst (when the flag is set).
//   * TKEEP   = WSTRB (byte lane 0 = first byte in memory, little-endian).
//               On the last beat WSTRB tells how many bytes are valid.
// Burst must be INCR, 64-bit (AWSIZE=3), 8-byte aligned; otherwise the burst is
// consumed, dropped, and answered with SLVERR.
// ============================================================================
module axi3_input_if #(
    parameter ID_W         = 12,
    parameter DOC_LAST_BIT = 24,
    parameter FIFO_ADDR_W  = 4
)(
    input  wire              h2f_axi_clk,
    input  wire              h2f_axi_rst_n,
    input  wire              core_clk,
    input  wire              core_rst_n,

    // AXI3 slave (write channels only)
    input  wire [ID_W-1:0]   s_axi_awid,
    input  wire [31:0]       s_axi_awaddr,
    input  wire [3:0]        s_axi_awlen,
    input  wire [2:0]        s_axi_awsize,
    input  wire [1:0]        s_axi_awburst,
    input  wire              s_axi_awvalid,
    output wire              s_axi_awready,
    input  wire [ID_W-1:0]   s_axi_wid,
    input  wire [63:0]       s_axi_wdata,
    input  wire [7:0]        s_axi_wstrb,
    input  wire              s_axi_wlast,
    input  wire              s_axi_wvalid,
    output wire              s_axi_wready,
    output wire [ID_W-1:0]   s_axi_bid,
    output wire [1:0]        s_axi_bresp,
    output wire              s_axi_bvalid,
    input  wire              s_axi_bready,

    // AXI4-Stream master (core_clk)
    output wire [63:0]       m_axis_tdata,
    output wire              m_axis_tvalid,
    input  wire              m_axis_tready,
    output wire              m_axis_tlast,
    output wire [7:0]        m_axis_tkeep,
    output wire [15:0]       m_axis_tuser
);
    // ---------------- AXI3 write slave FSM (h2f_axi_clk) --------------------
    localparam ST_IDLE = 2'd0, ST_DATA = 2'd1, ST_RESP = 2'd2;

    reg  [1:0]      st;
    reg  [ID_W-1:0] id_q;
    reg             last_q, err_q;
    wire            fifo_full;

    assign s_axi_awready = (st == ST_IDLE);
    assign s_axi_wready  = (st == ST_DATA) & (err_q | ~fifo_full);
    wire   w_fire        = s_axi_wvalid & s_axi_wready;
    wire   push          = w_fire & ~err_q;

    always @(posedge h2f_axi_clk or negedge h2f_axi_rst_n)
        if (!h2f_axi_rst_n) begin
            st <= ST_IDLE; id_q <= {ID_W{1'b0}}; last_q <= 1'b0; err_q <= 1'b0;
        end else begin
            case (st)
            ST_IDLE: if (s_axi_awvalid) begin
                id_q   <= s_axi_awid;
                last_q <= s_axi_awaddr[DOC_LAST_BIT];
                err_q  <= (s_axi_awsize  != 3'd3) |
                          (s_axi_awburst != 2'b01) |
                          (s_axi_awaddr[2:0] != 3'd0);
                st     <= ST_DATA;
            end
            ST_DATA: if (w_fire & s_axi_wlast) st <= ST_RESP;
            ST_RESP: if (s_axi_bready)         st <= ST_IDLE;
            default: st <= ST_IDLE;
            endcase
        end

    assign s_axi_bvalid = (st == ST_RESP);
    assign s_axi_bresp  = err_q ? 2'b10 : 2'b00;   // SLVERR / OKAY
    assign s_axi_bid    = id_q;

    // ---------------- dual-clock FIFO: h2f_axi_clk -> core_clk --------------
    // {tuser[15:0], tkeep[7:0], tlast, tdata[63:0]}
    wire [88:0] fifo_wdata = { {{(16-ID_W){1'b0}}, id_q},
                               s_axi_wstrb,
                               (s_axi_wlast & last_q),
                               s_axi_wdata };
    wire [88:0] fifo_rdata;
    wire        fifo_empty;

    async_fifo #(.WIDTH(89), .ADDR_W(FIFO_ADDR_W)) u_fifo (
        .wclk (h2f_axi_clk), .wrst_n(h2f_axi_rst_n),
        .winc (push), .wdata(fifo_wdata), .wfull(fifo_full),
        .rclk (core_clk),    .rrst_n(core_rst_n),
        .rinc (m_axis_tvalid & m_axis_tready),
        .rdata(fifo_rdata),  .rempty(fifo_empty)
    );

    assign m_axis_tvalid = ~fifo_empty;
    assign m_axis_tdata  = fifo_rdata[63:0];
    assign m_axis_tlast  = fifo_rdata[64];
    assign m_axis_tkeep  = fifo_rdata[72:65];
    assign m_axis_tuser  = fifo_rdata[88:73];
endmodule
