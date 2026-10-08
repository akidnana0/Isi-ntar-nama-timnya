// ============================================================================
// work_dispatcher.v : FSM Work Dispatcher (Load Balancer)
//
//   IDLE   : wait for a block from the Block Splitter (and run=1)
//   ALLOC  : FIRST block of a document -> round-robin pick of a free, enabled core;
//            record Job ID -> core in the tracking table
//   LOOKUP : continuation block -> core currently owned by this stream context
//   SEND   : present block to the selected core until it accepts (valid/ready)
//
// A core stays "assigned" until the Result Aggregator releases it
// (core_release = result_ack), so one document never leaves its core.
// Backpressure: blk_ready is low unless SEND with a ready core.
//
// v2: routing uses the stream context (blk_ctx) instead of a Job-ID search.
// Job IDs are now only carried to the result; duplicate IDs no longer stall
// allocation (v1 refused to start a document whose ID was still in flight,
// which serialised push mode, where every document has the same AWID).
// ============================================================================
module work_dispatcher #(
    parameter N    = 12,
    parameter NCTX = 16,
    parameter CW   = 4
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              en,                  // run

    input  wire [1023:0]     blk_data,
    input  wire [15:0]       blk_user,
    input  wire              blk_valid,
    output wire              blk_ready,
    input  wire              blk_first,
    input  wire              blk_last,
    input  wire [CW-1:0]     blk_ctx,

    input  wire [N-1:0]      core_en,
    input  wire [N-1:0]      core_blk_ready,
    input  wire [N-1:0]      core_release,

    output wire [N-1:0]      core_blk_valid,
    output wire [1023:0]     core_data,
    output wire [15:0]       core_user,
    output wire              core_first,
    output wire              core_last,
    output wire [N-1:0]      core_assigned
);
    localparam D_IDLE = 2'd0, D_ALLOC = 2'd1, D_LOOKUP = 2'd2, D_SEND = 2'd3;

    reg [1:0]       st;
    reg [N-1:0]     assigned;
    reg [4:0]       ctx_core [0:NCTX-1];   // context -> core holding its document
    reg [4:0]       sel, rr;

    // ---- round-robin free-core search --------------------------------------
    reg         a_found;
    reg [4:0]   a_idx;
    integer     i, k;
    always @* begin
        a_found = 1'b0; a_idx = 5'd0;
        for (i = 0; i < N; i = i + 1) begin
            k = rr + i;
            if (k >= N) k = k - N;
            if (!a_found && core_en[k] && !assigned[k]) begin
                a_found = 1'b1; a_idx = k[4:0];
            end
        end
    end

    wire send_fire = (st == D_SEND) & blk_valid & core_blk_ready[sel];

    integer r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= D_IDLE; assigned <= {N{1'b0}}; sel <= 0; rr <= 0;
            for (r = 0; r < NCTX; r = r + 1) ctx_core[r] <= 5'd0;
        end else begin
            assigned <= assigned & ~core_release;      // release (different core than set below)

            case (st)
            D_IDLE: if (en && blk_valid) st <= blk_first ? D_ALLOC : D_LOOKUP;

            D_ALLOC: if (a_found) begin
                sel               <= a_idx;
                assigned[a_idx]   <= 1'b1;
                ctx_core[blk_ctx] <= a_idx;
                rr                <= (a_idx + 5'd1 >= N) ? 5'd0 : a_idx + 5'd1;
                st                <= D_SEND;
            end

            D_LOOKUP: begin
                sel <= ctx_core[blk_ctx];
                st  <= D_SEND;
            end

            D_SEND: if (send_fire) st <= D_IDLE;
            endcase
        end

    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_v
        assign core_blk_valid[g] = (st == D_SEND) & blk_valid & (sel == g);
    end endgenerate

    assign blk_ready     = (st == D_SEND) & core_blk_ready[sel];
    assign core_data     = blk_data;
    assign core_user     = blk_user;
    assign core_first    = blk_first;
    assign core_last     = blk_last;
    assign core_assigned = assigned;
endmodule
