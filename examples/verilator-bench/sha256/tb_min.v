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
    initial begin
        block = 512'b0;
        block[31:0]    = 32'h61626380;
        block[511:480] = 32'h00000018;
        $display("[%0t] reset", $time);
        repeat (4) @(posedge clk);
        rst = 0;
        $display("[%0t] start", $time);
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;
        // Cycle limit to break a possible hang
        fork
            begin
                wait (done);
                $display("[%0t] done; h0=%h", $time, digest[255:224]);
                $finish;
            end
            begin
                repeat (200) @(posedge clk);
                $display("[%0t] TIMEOUT done=%b", $time, done);
                $finish;
            end
        join_any
    end
endmodule
