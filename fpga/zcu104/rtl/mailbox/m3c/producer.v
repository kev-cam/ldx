module producer(input clk, input rst, output reg [31:0] x);
  always @(posedge clk) if (rst) x <= 0; else x <= x + 1;
endmodule
