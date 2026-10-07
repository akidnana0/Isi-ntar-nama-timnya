// ============================================================================
// tb_sha512_path.sv : self-checking testbench for the SHA-512 plane
//   stream -> block_splitter -> work_dispatcher -> N x sha512_core -> result_aggregator
// Expected digests come from Python hashlib (vectors.svh via gen_vectors.py).
// Documents are streamed back-to-back; results are matched by Job ID (cores
// finish out of order).
// ============================================================================
`timescale 1ns/1ps
module tb_sha512_path;
    localparam N = 12;
    localparam MAXB = 256;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // stream into splitter
    reg  [63:0] s_tdata;  reg s_tvalid; wire s_tready; reg s_tlast; reg [7:0] s_tkeep; reg [15:0] s_tuser;

    wire [1023:0] sp_data; wire [15:0] sp_user; wire sp_valid, sp_ready, sp_first, sp_last;
    block_splitter u_bs (.clk(clk), .rst_n(rst_n),
        .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
        .s_tkeep(s_tkeep), .s_tuser(s_tuser),
        .blk_data(sp_data), .blk_user(sp_user), .blk_valid(sp_valid), .blk_ready(sp_ready),
        .blk_first(sp_first), .blk_last(sp_last), .idle());

    wire [N-1:0] c_valid, c_ready, c_busy, c_done, c_rel, c_assigned;
    wire [1023:0] c_data; wire [15:0] c_user; wire c_first, c_last;
    work_dispatcher #(.N(N)) u_wd (.clk(clk), .rst_n(rst_n), .en(1'b1),
        .blk_data(sp_data), .blk_user(sp_user), .blk_valid(sp_valid), .blk_ready(sp_ready),
        .blk_first(sp_first), .blk_last(sp_last),
        .core_en({N{1'b1}}), .core_blk_ready(c_ready), .core_release(c_rel),
        .core_blk_valid(c_valid), .core_data(c_data), .core_user(c_user),
        .core_first(c_first), .core_last(c_last), .core_assigned(c_assigned));

    wire [N*512-1:0] c_digest; wire [N*16-1:0] c_job;
    genvar g;
    generate for (g = 0; g < N; g = g + 1) begin : gc
        sha512_core u_core (.clk(clk), .rst_n(rst_n), .clk_en(1'b1),
            .blk_valid(c_valid[g]), .blk_ready(c_ready[g]),
            .blk_data(c_data), .blk_user(c_user), .blk_first(c_first), .blk_last(c_last),
            .busy(c_busy[g]), .done(c_done[g]),
            .digest(c_digest[g*512 +: 512]), .job_id(c_job[g*16 +: 16]), .result_ack(c_rel[g]));
    end endgenerate

    wire [511:0] r_tdata; wire r_tvalid, r_tlast; wire [15:0] r_tuser;
    reg r_tready;
    result_aggregator #(.N(N)) u_ra (.clk(clk), .rst_n(rst_n),
        .core_done(c_done), .core_digest(c_digest), .core_job(c_job), .result_ack(c_rel),
        .m_tdata(r_tdata), .m_tvalid(r_tvalid), .m_tready(r_tready),
        .m_tlast(r_tlast), .m_tuser(r_tuser));

    // ---------------- expected / collected results --------------------------
    reg [511:0] exp_dig [1:64];
    reg [511:0] got_dig [1:64];
    reg         got_flag[1:64];
    integer     results = 0, errors = 0, k;

    // random back-pressure on the result stream
    always @(posedge clk) r_tready <= ($urandom % 4) != 0;

    always @(posedge clk)
        if (rst_n && r_tvalid && r_tready) begin
            if (!r_tlast) begin errors = errors + 1; $display("ERROR: TLAST not set"); end
            got_dig [r_tuser] = r_tdata;
            got_flag[r_tuser] = 1'b1;
            results = results + 1;
        end

    // ---------------- stimulus ----------------------------------------------
    task send_word(input [63:0] d, input [7:0] keep, input last, input [15:0] job);
        begin
            s_tdata <= d; s_tkeep <= keep; s_tlast <= last; s_tuser <= job; s_tvalid <= 1'b1;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
            s_tvalid <= 1'b0;
            // occasional gaps on the input stream
            if ($urandom % 3 == 0) repeat ($urandom % 3) @(posedge clk);
        end
    endtask

    task do_doc(input [15:0] job, input [15:0] len, input [MAXB*8-1:0] msg, input [511:0] exp);
        integer nw, w, nb;
        reg [63:0] word; reg [7:0] keep;
        begin
            exp_dig[job] = exp; got_flag[job] = 1'b0;
            nw = (len + 7) / 8;
            if (len == 0) begin
                send_word(64'd0, 8'h00, 1'b1, job);
            end else begin
                for (w = 0; w < nw; w = w + 1) begin
                    word = msg[w*64 +: 64];
                    nb   = (w == nw-1 && (len % 8) != 0) ? (len % 8) : 8;
                    keep = (9'd1 << nb) - 1;
                    send_word(word, keep, (w == nw-1), job);
                end
            end
        end
    endtask

    `include "vectors.svh"

    initial begin
        s_tvalid = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_tuser = 0; r_tready = 0;
        for (k = 1; k <= 64; k = k + 1) got_flag[k] = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);

        run_all_docs;

        // wait for all results (timeout guard)
        k = 0;
        while (results < NDOCS && k < 200000) begin @(posedge clk); k = k + 1; end

        for (k = 1; k <= NDOCS; k = k + 1) begin
            if (!got_flag[k]) begin
                errors = errors + 1; $display("FAIL job %0d : no result", k);
            end else if (got_dig[k] !== exp_dig[k]) begin
                errors = errors + 1;
                $display("FAIL job %0d\n  got %h\n  exp %h", k, got_dig[k], exp_dig[k]);
            end else
                $display("PASS job %0d", k);
        end
        if (errors == 0) $display("ALL %0d TESTS PASSED", NDOCS);
        else             $display("%0d ERROR(S)", errors);
        $finish;
    end
endmodule
