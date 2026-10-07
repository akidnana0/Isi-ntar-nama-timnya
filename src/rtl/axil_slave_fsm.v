// ============================================================================
// axil_slave_fsm.v : AXI-Lite slave for the Control Register Bank (lwh2f bridge)
//
// WRITE: IDLE -> WRITE_ADDR -> WRITE_DATA -> WRITE_REG -> WRITE_RESP -> DONE
// READ : IDLE -> READ_ADDR  -> READ_REG   -> READ_DATA  -> DONE
// Invalid / unaligned address (outside 0x00..0x2C) -> SLVERR (10), no register
// access, and axi_err_pulse (-> ERROR_FLAGS[0]).
// ============================================================================
module axil_slave_fsm #(
    parameter ADDR_W = 8
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire [ADDR_W-1:0] s_axil_awaddr,
    input  wire              s_axil_awvalid,
    output wire              s_axil_awready,
    input  wire [31:0]       s_axil_wdata,
    input  wire [3:0]        s_axil_wstrb,
    input  wire              s_axil_wvalid,
    output wire              s_axil_wready,
    output wire [1:0]        s_axil_bresp,
    output wire              s_axil_bvalid,
    input  wire              s_axil_bready,

    input  wire [ADDR_W-1:0] s_axil_araddr,
    input  wire              s_axil_arvalid,
    output wire              s_axil_arready,
    output wire [31:0]       s_axil_rdata,
    output wire [1:0]        s_axil_rresp,
    output wire              s_axil_rvalid,
    input  wire              s_axil_rready,

    // to Control Register Bank
    output wire              reg_wr_en,
    output wire [ADDR_W-1:0] reg_waddr,
    output wire [31:0]       reg_wdata,
    output wire [3:0]        reg_wstrb,
    output wire [ADDR_W-1:0] reg_raddr,
    input  wire [31:0]       reg_rdata,

    output wire              axi_err_pulse
);
    function addr_ok(input [ADDR_W-1:0] a);
        addr_ok = (a[1:0] == 2'b00) && (a[ADDR_W-1:2] <= 11);   // 0x00..0x2C
    endfunction

    // ------------------------------ write FSM -------------------------------
    localparam W_IDLE=3'd0, W_ADDR=3'd1, W_DATA=3'd2, W_REG=3'd3, W_RESP=3'd4, W_DONE=3'd5;
    reg [2:0]        ws;
    reg [ADDR_W-1:0] waddr_q;
    reg [31:0]       wdata_q;
    reg [3:0]        wstrb_q;
    reg              werr_q;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ws <= W_IDLE; waddr_q <= 0; wdata_q <= 0; wstrb_q <= 0; werr_q <= 0;
        end else case (ws)
            W_IDLE: if (s_axil_awvalid) ws <= W_ADDR;
            W_ADDR: begin                       // AWREADY asserted this cycle
                waddr_q <= s_axil_awaddr;
                werr_q  <= ~addr_ok(s_axil_awaddr);
                ws      <= W_DATA;
            end
            W_DATA: if (s_axil_wvalid) begin    // WREADY asserted this state
                wdata_q <= s_axil_wdata;
                wstrb_q <= s_axil_wstrb;
                ws      <= W_REG;
            end
            W_REG:  ws <= W_RESP;               // reg_wr_en pulse
            W_RESP: if (s_axil_bready) ws <= W_DONE;
            W_DONE: ws <= W_IDLE;
            default: ws <= W_IDLE;
        endcase

    assign s_axil_awready = (ws == W_ADDR);
    assign s_axil_wready  = (ws == W_DATA);
    assign s_axil_bvalid  = (ws == W_RESP);
    assign s_axil_bresp   = werr_q ? 2'b10 : 2'b00;
    assign reg_wr_en      = (ws == W_REG) & ~werr_q;
    assign reg_waddr      = waddr_q;
    assign reg_wdata      = wdata_q;
    assign reg_wstrb      = wstrb_q;

    // ------------------------------ read FSM --------------------------------
    localparam R_IDLE=3'd0, R_ADDR=3'd1, R_REG=3'd2, R_DATA=3'd3, R_DONE=3'd4;
    reg [2:0]        rs;
    reg [ADDR_W-1:0] raddr_q;
    reg [31:0]       rdata_q;
    reg              rerr_q;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            rs <= R_IDLE; raddr_q <= 0; rdata_q <= 0; rerr_q <= 0;
        end else case (rs)
            R_IDLE: if (s_axil_arvalid) rs <= R_ADDR;
            R_ADDR: begin                       // ARREADY asserted this cycle
                raddr_q <= s_axil_araddr;
                rerr_q  <= ~addr_ok(s_axil_araddr);
                rs      <= R_REG;
            end
            R_REG: begin                        // register mux settles on reg_rdata
                rdata_q <= rerr_q ? 32'd0 : reg_rdata;
                rs      <= R_DATA;
            end
            R_DATA: if (s_axil_rready) rs <= R_DONE;
            R_DONE: rs <= R_IDLE;
            default: rs <= R_IDLE;
        endcase

    assign s_axil_arready = (rs == R_ADDR);
    assign reg_raddr      = raddr_q;
    assign s_axil_rvalid  = (rs == R_DATA);
    assign s_axil_rdata   = rdata_q;
    assign s_axil_rresp   = rerr_q ? 2'b10 : 2'b00;

    assign axi_err_pulse  = ((ws == W_REG) & werr_q) | ((rs == R_REG) & rerr_q);
endmodule
