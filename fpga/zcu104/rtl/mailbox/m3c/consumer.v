module consumer(input clk, input rst, input [31:0] x, output reg [31:0] result);
  always @(posedge clk) if (rst) result <= 0; else result <= (x ^ 32'h5) + 1;
endmodule
