// ============================================================================
// system_fsm.v : FSM tingkat sistem (interaksi HPS <-> hardware)
//
//   IDLE   : tunggu CTRL[START]
//   CHECK  : validasi konfigurasi (JOB_COUNT != 0, minimal 1 core aktif);
//            tentukan mode: JOB_BASE != 0 -> pull (DMA reader baca descriptor),
//            JOB_BASE == 0 -> push (HPS DMA menulis lewat Input Interface)
//   LAUNCH : start_ack, launch core manager, (pull) pulse dma_start
//   RUN    : dokumen mengalir; JOB_COUNT berkurang tiap result ditulis ke DDR3
//   DRAIN  : JOB_COUNT == 0, tunggu semua core lepas job (all_done)
//   DONE   : STATUS[DONE]=1 (sticky sampai START berikutnya) -> IDLE
//   ERR    : cfg error / DMA error / watchdog timeout; keluar lewat CTRL[RESET]
// ============================================================================
module system_fsm #(
    parameter [31:0] TIMEOUT = 32'd400_000_000   // cycles tanpa progress
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        soft_reset,

    input  wire        ctrl_start,
    output wire        start_ack,
    input  wire [31:0] job_count,
    input  wire [31:0] job_base,
    input  wire        en_any,
    input  wire        all_done,
    input  wire        result_written,
    input  wire        dma_err,

    output wire        launch,
    output wire        stop,
    output wire        dma_start,
    output wire        pull_mode,
    output wire        sys_busy,
    output wire        sys_done,
    output wire        sys_error,
    output wire        cfg_err_pulse,
    output wire        timeout_pulse
);
    localparam S_IDLE=3'd0, S_CHECK=3'd1, S_LAUNCH=3'd2, S_RUN=3'd3,
               S_DRAIN=3'd4, S_DONE=3'd5, S_ERR=3'd6;

    reg [2:0]  st;
    reg        pull_r, done_r;
    reg [31:0] wd;

    wire cfg_bad = (job_count == 32'd0) | ~en_any;
    wire in_run  = (st == S_RUN) | (st == S_DRAIN);
    assign timeout_pulse = in_run & (wd == TIMEOUT);

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= S_IDLE; pull_r <= 1'b0; done_r <= 1'b0; wd <= 32'd0;
        end else begin
            // watchdog: reset on progress
            if (!in_run || result_written) wd <= 32'd0;
            else                           wd <= wd + 32'd1;

            case (st)
            S_IDLE:   if (ctrl_start) st <= S_CHECK;
            S_CHECK: begin
                pull_r <= (job_base != 32'd0);
                st     <= cfg_bad ? S_ERR : S_LAUNCH;
            end
            S_LAUNCH: begin done_r <= 1'b0; st <= S_RUN; end
            S_RUN:    if (dma_err | timeout_pulse) st <= S_ERR;
                      else if (job_count == 32'd0) st <= S_DRAIN;
            S_DRAIN:  if (dma_err | timeout_pulse) st <= S_ERR;
                      else if (all_done)           st <= S_DONE;
            S_DONE:   begin done_r <= 1'b1; st <= S_IDLE; end
            S_ERR:    if (soft_reset) st <= S_IDLE;
            default:  st <= S_IDLE;
            endcase
        end

    assign start_ack     = (st == S_LAUNCH);
    assign launch        = (st == S_LAUNCH);
    assign dma_start     = (st == S_LAUNCH) & pull_r;
    assign stop          = (st == S_DONE);
    assign pull_mode     = pull_r;
    assign sys_busy      = (st == S_LAUNCH) | in_run;
    assign sys_done      = done_r;
    assign sys_error     = (st == S_ERR);
    assign cfg_err_pulse = (st == S_CHECK) & cfg_bad;
endmodule
