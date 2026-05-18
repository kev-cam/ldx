// tb_iverilog.v — SystemVerilog testbench for Sha256 under iverilog.
// Runs N hashes of "abc" and prints wall time.
`timescale 1ns/1ps

module tb;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg [511:0] block;
    wire done;
    wire [255:0] digest;

    Sha256 dut (.clk(clk), .rst(rst), .start(start), .block(block),
                .done(done), .digest(digest));

    always #5 clk = ~clk;

    integer i;
    integer iters;
    integer t0_s, t0_us, t1_s, t1_us;
    real    wall_us, us_per_hash, khps;
    integer fail_count;
    integer arg_n;
    reg [31:0] expected [0:7];

    initial begin
        // iverilog $time is in simulator time, not wall time. We use
        // $system to call /bin/date and read back wall clock externally —
        // but simpler: use $rusage which gives elapsed wall seconds.
        iters = 100;
        if ($value$plusargs("ITERS=%d", arg_n)) iters = arg_n;
        expected[0] = 32'hba7816bf; expected[1] = 32'h8f01cfea;
        expected[2] = 32'h414140de; expected[3] = 32'h5dae2223;
        expected[4] = 32'hb00361a3; expected[5] = 32'h96177a9c;
        expected[6] = 32'hb410ff61; expected[7] = 32'hf20015ad;

        block = 512'b0;
        block[31:0]     = 32'h61626380;   // M_0
        block[511:480]  = 32'h00000018;   // M_15

        repeat (4) @(posedge clk);
        rst = 0;

        // Wall-clock around the inner loop using $realtime markers + an
        // external script-supplied subtraction is awkward; rely on the
        // wall-time reported by `time vvp ...` from the shell instead.
        fail_count = 0;
        for (i = 0; i < iters; i = i + 1) begin
            start = 1;
            @(posedge clk);
            start = 0;
            wait (done);
            @(posedge clk);
            if (i == 0) begin
                if (digest[255:224] !== expected[0] ||
                    digest[223:192] !== expected[1] ||
                    digest[191:160] !== expected[2] ||
                    digest[159:128] !== expected[3] ||
                    digest[127:96]  !== expected[4] ||
                    digest[ 95:64]  !== expected[5] ||
                    digest[ 63:32]  !== expected[6] ||
                    digest[ 31: 0]  !== expected[7])
                    fail_count = fail_count + 1;
            end
        end
        $display("hashes=%0d  digest=%h  fails=%0d",
                 iters, digest[255:224], fail_count);
        $finish;
    end
endmodule
