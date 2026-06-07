// hierarchical wrapper: producer feeds consumer over net x (the cut)
module top2(input clk, input rst, output [31:0] result);
  wire [31:0] x;
  producer u_p(.clk(clk), .rst(rst), .x(x));
  consumer u_c(.clk(clk), .rst(rst), .x(x), .result(result));
endmodule
