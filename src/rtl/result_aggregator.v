// ============================================================================
// result_aggregator.v : FSM Result Aggregator
//
//   IDLE : round-robin arbiter over core_done[] (cores finish out-of-order)
//   SEND : one AXI4-Stream beat {TDATA = 512-bit digest, TUSER = Job ID,
//          TLAST = 1}; on TREADY the core is released via result_ack[sel]
//          (core leaves DONE, dispatcher frees the core).
// Output FIFO full -> TREADY low -> finished cores simply keep holding results
// (they stall, nothing is lost).
// ============================================================================
module result_aggregator #(
    parameter N = 12
)(
    input  wire             clk,
    input  wire             rst_n,

    input  wire [N-1:0]     core_done,
    input  wire [N*512-1:0] core_digest,
    input  wire [N*16-1:0]  core_job,
    output wire [N-1:0]     result_ack,

    output wire [511:0]     m_tdata,
    output wire             m_tvalid,
    input  wire             m_tready,
    output wire             m_tlast,
    output wire [15:0]      m_tuser
);
    localparam A_IDLE = 1'b0, A_SEND = 1'b1;

    reg         st;
    reg [4:0]   sel, rr;

    reg         found;
    reg [4:0]   idx;
    integer     i, k;
    always @* begin
        found = 1'b0; idx = 5'd0;
        for (i = 0; i < N; i = i + 1) begin
            k = rr + i;
            if (k >= N) k = k - N;
            if (!found && core_done[k]) begin found = 1'b1; idx = k[4:0]; end
        end
    end

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin st <= A_IDLE; sel <= 0; rr <= 0; end
        else case (st)
            A_IDLE: if (found) begin sel <= idx; st <= A_SEND; end
            A_SEND: if (m_tready) begin
                rr <= (sel + 5'd1 >= N) ? 5'd0 : sel + 5'd1;
                st <= A_IDLE;
            end
        endcase

    assign m_tvalid = (st == A_SEND);
    assign m_tdata  = core_digest[sel*512 +: 512];
    assign m_tuser  = core_job[sel*16 +: 16];
    assign m_tlast  = 1'b1;

    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : g_ack
        assign result_ack[g] = (st == A_SEND) & m_tready & (sel == g);
    end endgenerate
endmodule
