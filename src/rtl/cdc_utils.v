// ============================================================================
// cdc_utils.v : reset synchronizer, pulse synchronizer, dual-clock FIFO
// ============================================================================

// Async assert, sync de-assert reset
module rst_sync (
    input  wire clk,
    input  wire arst_n,
    output wire rst_n
);
    reg [1:0] q;
    always @(posedge clk or negedge arst_n)
        if (!arst_n) q <= 2'b00;
        else         q <= {q[0], 1'b1};
    assign rst_n = q[1];
endmodule

// Toggle based single-cycle pulse synchronizer (src -> dst)
module pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire pulse_in,
    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire pulse_out
);
    reg       tog;
    reg [2:0] s;
    always @(posedge src_clk or negedge src_rst_n)
        if (!src_rst_n)    tog <= 1'b0;
        else if (pulse_in) tog <= ~tog;
    always @(posedge dst_clk or negedge dst_rst_n)
        if (!dst_rst_n) s <= 3'b000;
        else            s <= {s[1:0], tog};
    assign pulse_out = s[2] ^ s[1];
endmodule

// Dual-clock FIFO, gray-coded pointers, first-word-fall-through read.
// DEPTH = 2**ADDR_W (ADDR_W >= 2). Memory is async-read (MLAB/FF friendly).
module async_fifo #(
    parameter WIDTH  = 64,
    parameter ADDR_W = 4
)(
    input  wire             wclk,
    input  wire             wrst_n,
    input  wire             winc,
    input  wire [WIDTH-1:0] wdata,
    output wire             wfull,
    input  wire             rclk,
    input  wire             rrst_n,
    input  wire             rinc,
    output wire [WIDTH-1:0] rdata,
    output wire             rempty
);
    localparam DEPTH = 1 << ADDR_W;

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_W:0]  wbin, wgray, rbin, rgray;
    reg [ADDR_W:0]  rg_w1, rg_w2;     // read gray -> write domain
    reg [ADDR_W:0]  wg_r1, wg_r2;     // write gray -> read domain
    reg             wfull_r, rempty_r;

    wire            wpush   = winc & ~wfull_r;
    wire [ADDR_W:0] wbin_n  = wbin + {{ADDR_W{1'b0}}, wpush};
    wire [ADDR_W:0] wgray_n = (wbin_n >> 1) ^ wbin_n;

    wire            rpop    = rinc & ~rempty_r;
    wire [ADDR_W:0] rbin_n  = rbin + {{ADDR_W{1'b0}}, rpop};
    wire [ADDR_W:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

    always @(posedge wclk or negedge wrst_n)
        if (!wrst_n) begin
            wbin <= 0; wgray <= 0; wfull_r <= 1'b0;
        end else begin
            wbin    <= wbin_n;
            wgray   <= wgray_n;
            wfull_r <= (wgray_n == {~rg_w2[ADDR_W:ADDR_W-1], rg_w2[ADDR_W-2:0]});
        end

    always @(posedge wclk)
        if (wpush) mem[wbin[ADDR_W-1:0]] <= wdata;

    always @(posedge wclk or negedge wrst_n)
        if (!wrst_n) begin rg_w1 <= 0; rg_w2 <= 0; end
        else         begin rg_w1 <= rgray; rg_w2 <= rg_w1; end

    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n) begin
            rbin <= 0; rgray <= 0; rempty_r <= 1'b1;
        end else begin
            rbin     <= rbin_n;
            rgray    <= rgray_n;
            rempty_r <= (rgray_n == wg_r2);
        end

    always @(posedge rclk or negedge rrst_n)
        if (!rrst_n) begin wg_r1 <= 0; wg_r2 <= 0; end
        else         begin wg_r1 <= wgray; wg_r2 <= wg_r1; end

    assign rdata  = mem[rbin[ADDR_W-1:0]];
    assign wfull  = wfull_r;
    assign rempty = rempty_r;
endmodule
