// ============================================================================
// core_manager.v : Core Manager
//   * CORE_EN is SNAPSHOTTED at launch (en_run). Changing CORE_EN while a run
//     is active has no effect until the next START (v1 used the live register:
//     disabling a core mid-run reset it while it still owned a document).
//   * Power saving: disabled cores get core_clk_en = 0 (clock ENABLE, maps onto
//     Cyclone V register CE). No combinational reset gating any more (v1 fed
//     core_en & rst_n straight into the cores' asynchronous reset).
//   * Job launch: `run` goes high on `launch`; the dispatcher only dispatches
//     while run=1.
//   * Completion tracking: all_done = run && no enabled core holds a job.
// ============================================================================
module core_manager #(
    parameter N = 12
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] core_en,          // live CORE_EN (from register bank)
    input  wire         launch,
    input  wire         stop,
    input  wire [N-1:0] core_assigned,    // from dispatcher (job in flight / result pending)
    output wire [N-1:0] core_clk_en,
    output wire [N-1:0] core_en_run,      // snapshot used by the datapath
    output reg          run,
    output wire         all_done
);
    reg [N-1:0] en_run;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin run <= 1'b0; en_run <= {N{1'b0}}; end
        else if (launch) begin run <= 1'b1; en_run <= core_en; end
        else if (stop)   run <= 1'b0;

    assign core_clk_en = en_run;
    assign core_en_run = en_run;
    assign all_done    = run & ~(|(core_assigned & en_run));
endmodule
