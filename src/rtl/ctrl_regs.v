// ============================================================================
// ctrl_regs.v : Control Register Bank
//
//  0x00 CTRL         R/W   [0]START [1]RESET(sc) [2]FLUSH(sc) [3]IRQ_GLOBAL_EN [7:4]CORE_COUNT
//  0x04 STATUS       R     [0]BUSY [1]DONE [2]ERROR [3]IDLE
//  0x08 CORE_EN      R/W   [15:0]
//  0x0C IRQ_EN       R/W   [2:0]
//  0x10 IRQ_STATUS   R/W1C [2:0]
//  0x14 JOB_BASE     R/W
//  0x18 JOB_COUNT    R/W   (decremented once per result packet written to DDR3)
//  0x1C VERSION      R
//  0x20 CORE_STATUS  R     [15:0]
//  0x24 ERROR_FLAGS  R/W1C [2:0]
//  0x28 RESULT_BASE  R/W   (EXTRA: base of result ring in DDR3, 128B aligned)
//  0x2C RESULT_SLOTS R/W   (EXTRA: number of 128B result slots, 0 = 1 slot)
//
// CORE_EN has priority; if CORE_EN == 0, CORE_COUNT enables cores [COUNT-1:0].
// ============================================================================
module ctrl_regs #(
    parameter N       = 12,
    parameter VERSION = 32'h0001_0001
)(
    input  wire         clk,
    input  wire         rst_n,

    // from AXI-Lite slave FSM
    input  wire         reg_wr_en,
    input  wire [7:0]   reg_waddr,
    input  wire [31:0]  reg_wdata,
    input  wire [3:0]   reg_wstrb,
    input  wire [7:0]   reg_raddr,
    output reg  [31:0]  reg_rdata,

    // control outputs
    output wire         ctrl_start,
    input  wire         start_ack,
    output wire         soft_reset,        // 1-cycle pulse
    output wire         fifo_flush,        // 1-cycle pulse
    output wire         irq_global_en,
    output wire [N-1:0] core_en_eff,
    output wire [2:0]   irq_en,
    output wire [2:0]   irq_w1c,
    input  wire [2:0]   irq_status,
    output wire [31:0]  job_base,
    output wire [31:0]  job_count,
    input  wire         job_dec,
    output wire [31:0]  result_base,
    output wire [31:0]  result_slots,

    // status inputs
    input  wire         st_busy,
    input  wire         st_done,
    input  wire         st_idle,
    input  wire         sys_error,
    input  wire [N-1:0] core_busy,
    input  wire [2:0]   err_set,
    output wire         err_any
);
    localparam A_CTRL=8'h00, A_STATUS=8'h04, A_CORE_EN=8'h08, A_IRQ_EN=8'h0C,
               A_IRQ_ST=8'h10, A_JOB_BASE=8'h14, A_JOB_CNT=8'h18, A_VERSION=8'h1C,
               A_CORE_ST=8'h20, A_ERR=8'h24, A_RES_BASE=8'h28, A_RES_SLOTS=8'h2C;

    function [31:0] mrg(input [31:0] o, input [31:0] n, input [3:0] s);
        mrg = { s[3] ? n[31:24] : o[31:24], s[2] ? n[23:16] : o[23:16],
                s[1] ? n[15:8]  : o[15:8],  s[0] ? n[7:0]   : o[7:0] };
    endfunction

    wire wr_ctrl  = reg_wr_en && reg_waddr == A_CTRL;
    wire wr_cen   = reg_wr_en && reg_waddr == A_CORE_EN;
    wire wr_irqen = reg_wr_en && reg_waddr == A_IRQ_EN;
    wire wr_irqst = reg_wr_en && reg_waddr == A_IRQ_ST;
    wire wr_jbase = reg_wr_en && reg_waddr == A_JOB_BASE;
    wire wr_jcnt  = reg_wr_en && reg_waddr == A_JOB_CNT;
    wire wr_err   = reg_wr_en && reg_waddr == A_ERR;
    wire wr_rbase = reg_wr_en && reg_waddr == A_RES_BASE;
    wire wr_rslot = reg_wr_en && reg_waddr == A_RES_SLOTS;

    reg        start_r, rst_p, flush_p, irq_gen_r;
    reg [3:0]  core_count_r;
    reg [15:0] core_en_r;
    reg [2:0]  irq_en_r, err_r;
    reg [31:0] jbase_r, jcnt_r, rbase_r, rslot_r;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            start_r <= 0; rst_p <= 0; flush_p <= 0; irq_gen_r <= 0; core_count_r <= 0;
            core_en_r <= 0; irq_en_r <= 0; err_r <= 0;
            jbase_r <= 0; jcnt_r <= 0; rbase_r <= 0; rslot_r <= 0;
        end else begin
            // self clearing pulses
            rst_p   <= wr_ctrl & reg_wstrb[0] & reg_wdata[1];
            flush_p <= wr_ctrl & reg_wstrb[0] & reg_wdata[2];

            // START: set by write-1, cleared when system FSM acknowledges
            if (start_ack | rst_p)                          start_r <= 1'b0;   // v2: RESET also clears a pending START
            else if (wr_ctrl & reg_wstrb[0] & reg_wdata[0]) start_r <= 1'b1;

            if (wr_ctrl & reg_wstrb[0]) begin
                irq_gen_r <= reg_wdata[3];
                core_count_r <= reg_wdata[7:4];
            end
            if (wr_cen)   core_en_r <= mrg({16'd0, core_en_r}, reg_wdata, reg_wstrb);
            if (wr_irqen) irq_en_r  <= reg_wdata[2:0];
            if (wr_jbase) jbase_r   <= mrg(jbase_r, reg_wdata, reg_wstrb);
            if (wr_rbase) rbase_r   <= mrg(rbase_r, reg_wdata, reg_wstrb);
            if (wr_rslot) rslot_r   <= mrg(rslot_r, reg_wdata, reg_wstrb);

            if (wr_jcnt)                       jcnt_r <= mrg(jcnt_r, reg_wdata, reg_wstrb);
            else if (job_dec && jcnt_r != 0)   jcnt_r <= jcnt_r - 32'd1;

            // W1C, set has priority over clear
            err_r <= (err_r & ~(wr_err ? reg_wdata[2:0] : 3'b000)) | err_set;
        end

    assign ctrl_start    = start_r;
    assign soft_reset    = rst_p;
    assign fifo_flush    = flush_p;
    assign irq_global_en = irq_gen_r;
    assign irq_en        = irq_en_r;
    assign irq_w1c       = (wr_irqst & reg_wstrb[0]) ? reg_wdata[2:0] : 3'b000;
    assign job_base      = jbase_r;
    assign job_count     = jcnt_r;
    assign result_base   = rbase_r;
    assign result_slots  = rslot_r;
    assign err_any       = |err_r;

    wire [16:0]  thermo = (17'd1 << core_count_r) - 17'd1;
    wire [N-1:0] en_sel = core_en_r[N-1:0];
    assign core_en_eff  = (|en_sel) ? en_sel : thermo[N-1:0];

    wire [31:0] status_w = {28'd0, st_idle, (err_any | sys_error), st_done, st_busy};

    always @* begin
        case (reg_raddr)
            A_CTRL:      reg_rdata = {24'd0, core_count_r, irq_gen_r, 2'b00, start_r};
            A_STATUS:    reg_rdata = status_w;
            A_CORE_EN:   reg_rdata = {16'd0, core_en_r};
            A_IRQ_EN:    reg_rdata = {29'd0, irq_en_r};
            A_IRQ_ST:    reg_rdata = {29'd0, irq_status};
            A_JOB_BASE:  reg_rdata = jbase_r;
            A_JOB_CNT:   reg_rdata = jcnt_r;
            A_VERSION:   reg_rdata = VERSION;
            A_CORE_ST:   reg_rdata = {{(32-N){1'b0}}, core_busy};
            A_ERR:       reg_rdata = {29'd0, err_r};
            A_RES_BASE:  reg_rdata = rbase_r;
            A_RES_SLOTS: reg_rdata = rslot_r;
            default:     reg_rdata = 32'd0;
        endcase
    end
endmodule
