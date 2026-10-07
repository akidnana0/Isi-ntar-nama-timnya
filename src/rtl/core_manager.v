// ============================================================================
// core_manager.v : Core Manager
//   * Clock gating / power saving: disabled cores get core_clk_en = 0 and are
//     held in reset (core_rst_n = 0). Implemented as clock-ENABLE (not a gated
//     clock) so it maps cleanly onto Cyclone V registers with CE.
//   * Job launch: `run` goes high on `launch` (issued by system FSM after it
//     has qualified CTRL[START]); the dispatcher only dispatches while run=1.
//   * Completion tracking: all_done = run && no enabled core holds a job.
// ============================================================================
module core_manager #(
    parameter N = 12
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] core_en,
    input  wire         launch,
    input  wire         stop,
    input  wire [N-1:0] core_assigned,   // from dispatcher (job in flight / result pending)
    output wire [N-1:0] core_clk_en,
    output wire [N-1:0] core_rst_n,
    output reg          run,
    output wire         all_done
);
    always @(posedge clk or negedge rst_n)
        if (!rst_n)      run <= 1'b0;
        else if (launch) run <= 1'b1;
        else if (stop)   run <= 1'b0;

    assign core_clk_en = core_en;
    assign core_rst_n  = core_en & {N{rst_n}};
    assign all_done    = run & ~(|(core_assigned & core_en));
endmodule
