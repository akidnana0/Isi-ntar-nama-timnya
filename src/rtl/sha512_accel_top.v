// ============================================================================
// sha512_accel_top.v : SHA-512 multi-core accelerator, fabric top-level
//
//  Control plane (core_clk): AXI-Lite slave FSM, register bank, IRQ ctrl,
//                            system FSM, core manager
//  Interface plane         : AXI3 input slave (push) / AXI3 DMA reader (pull) /
//                            AXI3 output master; FIFOs cross h2f_axi_clk <-> core_clk
//  SHA-512 plane (core_clk): block splitter -> dispatcher -> N cores -> aggregator
//
//  Note: l3_main_clk lives on the HPS side of the bridges, it is not a fabric port.
//  AXI-Lite slave, DMA reader and the control FSMs run in core_clk
//  (lwh2f / f2h-read bridge clocks must be tied to the same fabric clock).
// ============================================================================
module sha512_accel_top #(
    parameter N          = 12,             // <= 16 (CORE_EN is 16 bit)
    parameter ID_W       = 12,
    parameter WD_TIMEOUT = 32'd400_000_000
)(
    input  wire              core_clk,
    input  wire              core_rst_n,
    input  wire              h2f_axi_clk,
    input  wire              h2f_axi_rst_n,

    // ---- AXI-Lite slave (lwh2f bridge) -> control registers ----
    input  wire [7:0]        s_axil_awaddr,
    input  wire              s_axil_awvalid,
    output wire              s_axil_awready,
    input  wire [31:0]       s_axil_wdata,
    input  wire [3:0]        s_axil_wstrb,
    input  wire              s_axil_wvalid,
    output wire              s_axil_wready,
    output wire [1:0]        s_axil_bresp,
    output wire              s_axil_bvalid,
    input  wire              s_axil_bready,
    input  wire [7:0]        s_axil_araddr,
    input  wire              s_axil_arvalid,
    output wire              s_axil_arready,
    output wire [31:0]       s_axil_rdata,
    output wire [1:0]        s_axil_rresp,
    output wire              s_axil_rvalid,
    input  wire              s_axil_rready,

    // ---- AXI3 write slave (h2f bridge) : INPUT interface ----
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

    // ---- AXI3 read master (f2h bridge) : DMA reader ----
    output wire [11:0]       m_rd_arid,
    output wire [31:0]       m_rd_araddr,
    output wire [3:0]        m_rd_arlen,
    output wire [2:0]        m_rd_arsize,
    output wire [1:0]        m_rd_arburst,
    output wire              m_rd_arvalid,
    input  wire              m_rd_arready,
    input  wire [11:0]       m_rd_rid,
    input  wire [63:0]       m_rd_rdata,
    input  wire [1:0]        m_rd_rresp,
    input  wire              m_rd_rlast,
    input  wire              m_rd_rvalid,
    output wire              m_rd_rready,

    // ---- AXI3 write master (f2h bridge) : OUTPUT interface ----
    output wire [11:0]       m_wr_awid,
    output wire [31:0]       m_wr_awaddr,
    output wire [3:0]        m_wr_awlen,
    output wire [2:0]        m_wr_awsize,
    output wire [1:0]        m_wr_awburst,
    output wire              m_wr_awvalid,
    input  wire              m_wr_awready,
    output wire [11:0]       m_wr_wid,
    output wire [63:0]       m_wr_wdata,
    output wire [7:0]        m_wr_wstrb,
    output wire              m_wr_wlast,
    output wire              m_wr_wvalid,
    input  wire              m_wr_wready,
    input  wire [11:0]       m_wr_bid,
    input  wire [1:0]        m_wr_bresp,
    input  wire              m_wr_bvalid,
    output wire              m_wr_bready,

    output wire              fpga_irq
);
    // ------------------------------------------------------------------------
    // Resets: RESET / FLUSH reset the whole datapath incl. both FIFOs in both
    // clock domains (stretched, async assert, sync release).
    // v2: QUIESCE FIRST. v1 reset the AXI masters/slave in the middle of a
    // burst; the HPS bridge then waits forever for the missing R/W beats and
    // the f2h/h2f bridge hangs until the HPS is rebooted. Now the request
    // (rst_req) halts all AXI FSMs, waits until they are idle (timeout 4096
    // cycles as a last resort), and only then pulses the datapath reset.
    // ------------------------------------------------------------------------
    wire        soft_reset, fifo_flush;
    wire        dma_idle, out_idle_a, in_idle_a;
    reg  [3:0]  clr_cnt;
    reg         clr_active, rst_req;
    reg  [11:0] q_cnt;
    reg  [1:0]  out_idle_s, in_idle_s;
    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin out_idle_s <= 2'b11; in_idle_s <= 2'b11; end
        else begin out_idle_s <= {out_idle_s[0], out_idle_a}; in_idle_s <= {in_idle_s[0], in_idle_a}; end

    wire q_done = rst_req & (((q_cnt >= 12'd8) & dma_idle & out_idle_s[1] & in_idle_s[1]) | (&q_cnt));

    always @(posedge core_clk or negedge core_rst_n)
        if (!core_rst_n) begin clr_cnt <= 4'd0; clr_active <= 1'b0; rst_req <= 1'b0; q_cnt <= 12'd0; end
        else begin
            if (soft_reset | fifo_flush) begin rst_req <= 1'b1; q_cnt <= 12'd0; end
            else if (rst_req) begin q_cnt <= q_cnt + 12'd1; if (q_done) rst_req <= 1'b0; end

            if (q_done)                clr_cnt <= 4'd15;
            else if (clr_cnt != 4'd0)  clr_cnt <= clr_cnt - 4'd1;
            clr_active <= (clr_cnt != 4'd0);
        end
    wire rst_busy = rst_req | clr_active | (clr_cnt != 4'd0);

    // halt request into the h2f_axi_clk domain (level, 2-FF synchronizer)
    reg [1:0] halt_s;
    always @(posedge h2f_axi_clk or negedge h2f_axi_rst_n)
        if (!h2f_axi_rst_n) halt_s <= 2'b00; else halt_s <= {halt_s[0], rst_req};
    wire halt_a = halt_s[1];

    wire dp_arst_n  = core_rst_n & h2f_axi_rst_n & ~clr_active;
    wire core_dp_rst_n, axi_dp_rst_n;
    rst_sync u_rs_core (.clk(core_clk),    .arst_n(dp_arst_n), .rst_n(core_dp_rst_n));
    rst_sync u_rs_axi  (.clk(h2f_axi_clk), .arst_n(dp_arst_n), .rst_n(axi_dp_rst_n));

    // ------------------------------------------------------------------------
    // Control plane
    // ------------------------------------------------------------------------
    wire        reg_wr_en;
    wire [7:0]  reg_waddr, reg_raddr;
    wire [31:0] reg_wdata, reg_rdata;
    wire [3:0]  reg_wstrb;
    wire        axil_err;

    axil_slave_fsm u_axil (
        .clk(core_clk), .rst_n(core_rst_n),
        .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
        .reg_wr_en(reg_wr_en), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
        .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
        .axi_err_pulse(axil_err)
    );

    wire              ctrl_start, start_ack, irq_global_en;
    wire [N-1:0]      core_en_eff, core_en_run, core_busy, core_assigned, core_done, core_rel;
    localparam        NCTX = 16, CW = 4;
    function [CW:0] popcnt(input [N-1:0] v); integer b; begin
        popcnt = 0; for (b = 0; b < N; b = b + 1) popcnt = popcnt + v[b]; end endfunction
    wire [2:0]        irq_en, irq_w1c, irq_status, err_set;
    wire [31:0]       job_base, job_count, res_base, res_slots;
    wire              job_dec, st_busy, st_idle, sys_busy, sys_done, sys_error, err_any;

    ctrl_regs #(.N(N)) u_regs (
        .clk(core_clk), .rst_n(core_rst_n),
        .reg_wr_en(reg_wr_en), .reg_waddr(reg_waddr), .reg_wdata(reg_wdata), .reg_wstrb(reg_wstrb),
        .reg_raddr(reg_raddr), .reg_rdata(reg_rdata),
        .ctrl_start(ctrl_start), .start_ack(start_ack),
        .soft_reset(soft_reset), .fifo_flush(fifo_flush),
        .irq_global_en(irq_global_en), .core_en_eff(core_en_eff),
        .irq_en(irq_en), .irq_w1c(irq_w1c), .irq_status(irq_status),
        .job_base(job_base), .job_count(job_count), .job_dec(job_dec),
        .result_base(res_base), .result_slots(res_slots),
        .st_busy(st_busy), .st_done(sys_done), .st_idle(st_idle),
        .sys_error(sys_error), .core_busy(core_busy),
        .err_set(err_set), .err_any(err_any)
    );

    assign st_busy = |(core_busy & core_en_run);
    assign st_idle = ~sys_busy & ~(|core_busy) & ~rst_busy;

    wire launch, stop, dma_start, pull_mode, cfg_err, wd_timeout;
    wire all_done, dma_err, result_written, wr_err_core;

    system_fsm #(.TIMEOUT(WD_TIMEOUT)) u_sys (
        .clk(core_clk), .rst_n(core_rst_n), .soft_reset(soft_reset),
        .ctrl_start(ctrl_start & ~rst_busy), .start_ack(start_ack),
        .job_count(job_count), .job_base(job_base), .en_any(|core_en_eff),
        .all_done(all_done), .result_written(result_written), .dma_err(dma_err),
        .launch(launch), .stop(stop), .dma_start(dma_start), .pull_mode(pull_mode),
        .sys_busy(sys_busy), .sys_done(sys_done), .sys_error(sys_error),
        .cfg_err_pulse(cfg_err), .timeout_pulse(wd_timeout)
    );

    assign job_dec = result_written;
    // ERROR_FLAGS: [0] AXI/protocol/config error, [1] core timeout, [2] FIFO over/underflow (reserved, 0:
    // both FIFOs are back-pressured, so overflow cannot occur by construction)
    assign err_set = { 1'b0, wd_timeout, (axil_err | dma_err | wr_err_core | cfg_err) };

    irq_ctrl u_irq (
        .clk(core_clk), .rst_n(core_rst_n),
        .job_done_pulse(result_written), .error_pulse(|err_set), .fifo_ovf_pulse(err_set[2]),
        .irq_en(irq_en), .irq_global_en(irq_global_en), .irq_w1c(irq_w1c),
        .irq_status(irq_status), .fpga_irq(fpga_irq)
    );

    wire [N-1:0] core_clk_en;
    wire         run;
    core_manager #(.N(N)) u_cm (
        .clk(core_clk), .rst_n(core_dp_rst_n), .core_en(core_en_eff),
        .launch(launch), .stop(stop), .core_assigned(core_assigned),
        .core_clk_en(core_clk_en), .core_en_run(core_en_run),
        .run(run), .all_done(all_done)
    );

    // ------------------------------------------------------------------------
    // Interface plane - input side (push via AXI3 slave | pull via DMA reader)
    // ------------------------------------------------------------------------
    wire [63:0] in_tdata;  wire in_tvalid, in_tready, in_tlast;  wire [7:0] in_tkeep;  wire [15:0] in_tuser;
    wire [63:0] dr_tdata;  wire dr_tvalid, dr_tready, dr_tlast;  wire [7:0] dr_tkeep;  wire [15:0] dr_tuser;
    wire [CW-1:0] dr_tctx;
    wire          dma_busy;
    assign        dma_idle = ~dma_busy;

    axi3_input_if #(.ID_W(ID_W)) u_in (
        .h2f_axi_clk(h2f_axi_clk), .h2f_axi_rst_n(axi_dp_rst_n),
        .core_clk(core_clk),       .core_rst_n(core_dp_rst_n),
        .s_axi_awid(s_axi_awid), .s_axi_awaddr(s_axi_awaddr), .s_axi_awlen(s_axi_awlen),
        .s_axi_awsize(s_axi_awsize), .s_axi_awburst(s_axi_awburst),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wid(s_axi_wid), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wlast(s_axi_wlast), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bid(s_axi_bid), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .halt(halt_a), .idle(in_idle_a),
        .m_axis_tdata(in_tdata), .m_axis_tvalid(in_tvalid), .m_axis_tready(in_tready),
        .m_axis_tlast(in_tlast), .m_axis_tkeep(in_tkeep), .m_axis_tuser(in_tuser)
    );

    axi3_dma_reader #(.NCTX(NCTX), .CW(CW)) u_dma (
        .clk(core_clk), .rst_n(core_dp_rst_n),
        .start(dma_start), .job_base(job_base), .job_count(job_count),
        .max_ctx(popcnt(core_en_eff)),        // #open documents <= #cores (deadlock-free)
        .halt(rst_req),
        .m_axi_arid(m_rd_arid), .m_axi_araddr(m_rd_araddr), .m_axi_arlen(m_rd_arlen),
        .m_axi_arsize(m_rd_arsize), .m_axi_arburst(m_rd_arburst),
        .m_axi_arvalid(m_rd_arvalid), .m_axi_arready(m_rd_arready),
        .m_axi_rid(m_rd_rid), .m_axi_rdata(m_rd_rdata), .m_axi_rresp(m_rd_rresp),
        .m_axi_rlast(m_rd_rlast), .m_axi_rvalid(m_rd_rvalid), .m_axi_rready(m_rd_rready),
        .m_axis_tdata(dr_tdata), .m_axis_tvalid(dr_tvalid), .m_axis_tready(dr_tready),
        .m_axis_tlast(dr_tlast), .m_axis_tkeep(dr_tkeep), .m_axis_tuser(dr_tuser),
        .m_axis_tctx(dr_tctx),
        .busy(dma_busy), .err_pulse(dma_err)
    );

    // source mux, gated by run (documents wait in the FIFO until START)
    wire [63:0] bs_tdata  = pull_mode ? dr_tdata : in_tdata;
    wire        bs_tvalid = run & (pull_mode ? dr_tvalid : in_tvalid);
    wire        bs_tlast  = pull_mode ? dr_tlast : in_tlast;
    wire [7:0]  bs_tkeep  = pull_mode ? dr_tkeep : in_tkeep;
    wire [15:0] bs_tuser  = pull_mode ? dr_tuser : in_tuser;
    wire [CW-1:0] bs_tctx = pull_mode ? dr_tctx  : {CW{1'b0}};   // push mode = one sequential stream
    wire        bs_tready;
    assign dr_tready = run &  pull_mode & bs_tready;
    assign in_tready = run & ~pull_mode & bs_tready;

    // ------------------------------------------------------------------------
    // SHA-512 plane
    // ------------------------------------------------------------------------
    wire [1023:0] sp_data;  wire [15:0] sp_user;  wire sp_valid, sp_ready, sp_first, sp_last;
    wire [CW-1:0] sp_ctx;

    block_splitter #(.NCTX(NCTX), .CW(CW)) u_bs (
        .clk(core_clk), .rst_n(core_dp_rst_n),
        .s_tdata(bs_tdata), .s_tvalid(bs_tvalid), .s_tready(bs_tready),
        .s_tlast(bs_tlast), .s_tkeep(bs_tkeep), .s_tuser(bs_tuser), .s_tctx(bs_tctx),
        .blk_data(sp_data), .blk_user(sp_user), .blk_valid(sp_valid), .blk_ready(sp_ready),
        .blk_first(sp_first), .blk_last(sp_last), .blk_ctx(sp_ctx), .idle()
    );

    wire [N-1:0]  c_blk_valid, c_blk_ready;
    wire [1023:0] c_data;  wire [15:0] c_user;  wire c_first, c_last;

    work_dispatcher #(.N(N), .NCTX(NCTX), .CW(CW)) u_wd (
        .clk(core_clk), .rst_n(core_dp_rst_n), .en(run),
        .blk_data(sp_data), .blk_user(sp_user), .blk_valid(sp_valid), .blk_ready(sp_ready),
        .blk_first(sp_first), .blk_last(sp_last), .blk_ctx(sp_ctx),
        .core_en(core_en_run), .core_blk_ready(c_blk_ready), .core_release(core_rel),
        .core_blk_valid(c_blk_valid), .core_data(c_data), .core_user(c_user),
        .core_first(c_first), .core_last(c_last), .core_assigned(core_assigned)
    );

    wire [N*512-1:0] c_digest;
    wire [N*16-1:0]  c_job;

    genvar gc;
    generate for (gc = 0; gc < N; gc = gc + 1) begin : g_core
        sha512_core u_core (
            .clk(core_clk), .rst_n(core_dp_rst_n), .clk_en(core_clk_en[gc]),
            .blk_valid(c_blk_valid[gc]), .blk_ready(c_blk_ready[gc]),
            .blk_data(c_data), .blk_user(c_user), .blk_first(c_first), .blk_last(c_last),
            .busy(core_busy[gc]), .done(core_done[gc]),
            .digest(c_digest[gc*512 +: 512]), .job_id(c_job[gc*16 +: 16]),
            .result_ack(core_rel[gc])
        );
    end endgenerate

    wire [511:0] ra_tdata;  wire ra_tvalid, ra_tready, ra_tlast;  wire [15:0] ra_tuser;

    result_aggregator #(.N(N)) u_ra (
        .clk(core_clk), .rst_n(core_dp_rst_n),
        .core_done(core_done), .core_digest(c_digest), .core_job(c_job), .result_ack(core_rel),
        .m_tdata(ra_tdata), .m_tvalid(ra_tvalid), .m_tready(ra_tready),
        .m_tlast(ra_tlast), .m_tuser(ra_tuser)
    );

    // ------------------------------------------------------------------------
    // Interface plane - output side
    // ------------------------------------------------------------------------
    wire wr_done_axi, wr_err_axi;

    axi3_output_if u_out (
        .core_clk(core_clk), .core_rst_n(core_dp_rst_n),
        .h2f_axi_clk(h2f_axi_clk), .h2f_axi_rst_n(axi_dp_rst_n),
        .s_axis_tdata(ra_tdata), .s_axis_tvalid(ra_tvalid), .s_axis_tready(ra_tready),
        .s_axis_tlast(ra_tlast), .s_axis_tuser(ra_tuser),
        .res_base(res_base), .res_slots(res_slots),
        .m_axi_awid(m_wr_awid), .m_axi_awaddr(m_wr_awaddr), .m_axi_awlen(m_wr_awlen),
        .m_axi_awsize(m_wr_awsize), .m_axi_awburst(m_wr_awburst),
        .m_axi_awvalid(m_wr_awvalid), .m_axi_awready(m_wr_awready),
        .m_axi_wid(m_wr_wid), .m_axi_wdata(m_wr_wdata), .m_axi_wstrb(m_wr_wstrb),
        .m_axi_wlast(m_wr_wlast), .m_axi_wvalid(m_wr_wvalid), .m_axi_wready(m_wr_wready),
        .m_axi_bid(m_wr_bid), .m_axi_bresp(m_wr_bresp), .m_axi_bvalid(m_wr_bvalid), .m_axi_bready(m_wr_bready),
        .halt(halt_a), .idle(out_idle_a),
        .wr_done_pulse(wr_done_axi), .wr_err_pulse(wr_err_axi)
    );

    pulse_sync u_ps_done (.src_clk(h2f_axi_clk), .src_rst_n(axi_dp_rst_n), .pulse_in(wr_done_axi),
                          .dst_clk(core_clk),    .dst_rst_n(core_dp_rst_n), .pulse_out(result_written));
    pulse_sync u_ps_err  (.src_clk(h2f_axi_clk), .src_rst_n(axi_dp_rst_n), .pulse_in(wr_err_axi),
                          .dst_clk(core_clk),    .dst_rst_n(core_dp_rst_n), .pulse_out(wr_err_core));
    // v2: both ends of the pulse synchronizers are now reset by the SAME datapath
    // reset. v1 reset only the source toggle on RESET/FLUSH, which produced a
    // phantom result_written (JOB_COUNT-1, IRQ_STATUS[0]=1) after every soft reset.
endmodule
