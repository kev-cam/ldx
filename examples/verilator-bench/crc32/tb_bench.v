`timescale 1ns/1ps
module tb;
    reg clk = 0; reg rst = 1; reg en = 0; reg [7:0] data;
    wire [31:0] crc;
    Crc32 dut (.clk(clk), .rst(rst), .en(en), .data(data), .crc(crc));
    always #5 clk = ~clk;
    integer i, iters, arg;
    initial begin
        iters = 10000;
        if ($value$plusargs("ITERS=%d", arg)) iters = arg;
        repeat (4) @(posedge clk);
        rst = 0; en = 1;
        for (i = 0; i < iters; i = i + 1) begin
            data = i[7:0];
            @(posedge clk);
        end
        $display("crc=%h iters=%0d", crc, iters);
        $finish;
    end
endmodule
