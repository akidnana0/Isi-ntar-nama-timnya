// ============================================================================
// block_splitter.v : FSM Block Splitter & Padding (64-bit stream -> 1024-bit blocks)
//
// Input word convention: little-endian memory order (byte 0 in tdata[7:0]),
// tkeep[i] marks byte i valid (contiguous from byte 0, only meaningful on the
// TLAST beat). The splitter byte-reverses each word so the block is SHA-512
// big-endian. A TLAST beat with tkeep = 0 and no earlier beats = empty message.
//
// States:
//   COLLECT : accept words into the block buffer; 16 words -> EMIT
//             TLAST word -> merge 0x80 (or flag it pending if word is full) -> PAD
//   PAD     : one word per cycle: pending 0x80 word, zeros, then 128-bit length
//             in words 14/15. Spills into a 2nd block automatically.
//   EMIT    : present block (valid/ready); first/last flags for the dispatcher.
// ============================================================================
module block_splitter (
    input  wire          clk,
    input  wire          rst_n,

    input  wire [63:0]   s_tdata,
    input  wire          s_tvalid,
    output wire          s_tready,
    input  wire          s_tlast,
    input  wire [7:0]    s_tkeep,
    input  wire [15:0]   s_tuser,

    output wire [1023:0] blk_data,
    output wire [15:0]   blk_user,
    output wire          blk_valid,
    input  wire          blk_ready,
    output wire          blk_first,
    output wire          blk_last,
    output wire          idle
);
    localparam S_COLLECT = 2'd0, S_PAD = 2'd1, S_EMIT = 2'd2;

    reg [1:0]   st;
    reg [63:0]  w [0:15];
    reg [4:0]   wc;
    reg [127:0] bitlen;
    reg [15:0]  job;
    reg         first_f, final_f, padding, one_pend;

    // ---- input word conditioning -------------------------------------------
    wire [63:0] be = { s_tdata[7:0],   s_tdata[15:8],  s_tdata[23:16], s_tdata[31:24],
                       s_tdata[39:32], s_tdata[47:40], s_tdata[55:48], s_tdata[63:56] };
    wire [3:0]  n  = s_tkeep[0] + s_tkeep[1] + s_tkeep[2] + s_tkeep[3] +
                     s_tkeep[4] + s_tkeep[5] + s_tkeep[6] + s_tkeep[7];
    wire [63:0] mask   = (n == 4'd0) ? 64'd0 : (64'hFFFF_FFFF_FFFF_FFFF << (7'd64 - {n, 3'b000}));
    wire [63:0] one_w  = 64'h8000_0000_0000_0000 >> {n[2:0], 3'b000};
    wire [63:0] merged = (be & mask) | one_w;        // valid only when n < 8

    assign s_tready = (st == S_COLLECT);
    wire   acc      = s_tvalid & s_tready;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            st <= S_COLLECT; wc <= 0; bitlen <= 0; job <= 0;
            first_f <= 1'b1; final_f <= 1'b0; padding <= 1'b0; one_pend <= 1'b0;
        end else begin
            case (st)
            S_COLLECT: if (acc) begin
                job    <= s_tuser;
                bitlen <= bitlen + {121'd0, n, 3'b000};
                if (!s_tlast) begin
                    w[wc[3:0]] <= be;
                    wc <= wc + 5'd1;
                    if (wc == 5'd15) st <= S_EMIT;
                end else begin
                    if (n < 4'd8) begin w[wc[3:0]] <= merged; one_pend <= 1'b0; end
                    else          begin w[wc[3:0]] <= be;     one_pend <= 1'b1; end
                    wc      <= wc + 5'd1;
                    padding <= 1'b1;
                    st      <= S_PAD;
                end
            end

            S_PAD: begin
                if (wc == 5'd16) st <= S_EMIT;
                else if (one_pend) begin
                    w[wc[3:0]] <= 64'h8000_0000_0000_0000;
                    one_pend   <= 1'b0;
                    wc         <= wc + 5'd1;
                end else if (wc == 5'd14) begin
                    w[14]   <= bitlen[127:64];
                    w[15]   <= bitlen[63:0];
                    wc      <= 5'd16;
                    final_f <= 1'b1;
                end else begin
                    w[wc[3:0]] <= 64'd0;
                    wc         <= wc + 5'd1;
                end
            end

            S_EMIT: if (blk_ready) begin
                wc      <= 5'd0;
                first_f <= 1'b0;
                if (final_f) begin
                    final_f <= 1'b0; padding <= 1'b0; first_f <= 1'b1; bitlen <= 128'd0;
                    st <= S_COLLECT;
                end else
                    st <= padding ? S_PAD : S_COLLECT;
            end
            default: st <= S_COLLECT;
            endcase
        end

    genvar gi;
    generate for (gi = 0; gi < 16; gi = gi + 1) begin : g_blk
        assign blk_data[1023-64*gi -: 64] = w[gi];
    end endgenerate

    assign blk_valid = (st == S_EMIT);
    assign blk_user  = job;
    assign blk_first = first_f;
    assign blk_last  = final_f;
    assign idle      = (st == S_COLLECT) & (wc == 5'd0) & ~padding;
endmodule
