module top(input clk, input rst, output reg [31:0] result);
  reg [31:0] x;
  always @(posedge clk) if (rst) x <= 0; else x <= x + 1;
  always @(posedge clk) if (rst) result <= 0; else result <= (x ^ 32'h5) + 1;
endmodule
