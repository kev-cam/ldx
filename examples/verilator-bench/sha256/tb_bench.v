`timescale 1ns/1ps
module tb;
    reg clk = 0;
    reg rst = 1;
    reg start = 0;
    reg [511:0] block;
    wire done;
    wire [255:0] digest;
    Sha256 dut (.clk(clk), .rst(rst), .start(start), .block(block), .done(done), .digest(digest));
    always #5 clk = ~clk;
    integer i, iters, arg;
    initial begin
        iters = 100;
        if ($value$plusargs("ITERS=%d", arg)) iters = arg;
        block = 512'b0;
        block[31:0]    = 32'h61626380;
        block[511:480] = 32'h00000018;
        repeat (4) @(posedge clk);
        rst = 0;
        for (i = 0; i < iters; i = i + 1) begin
            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            // Just cycle 66 times — Sha256 finishes at ~65 cycles.
            repeat (66) @(posedge clk);
        end
        $display("done iters=%0d  digest=%h", iters, digest[255:224]);
        $finish;
    end
endmodule
