// self-driving FSM: xorshift32 PRNG (real, recognizable; mul-free, a few ops/cycle)
module stage(input clk, input rst, output reg [31:0] s);
  wire [31:0] a = s ^ (s << 13);
  wire [31:0] b = a ^ (a >> 17);
  wire [31:0] c = b ^ (b << 5);
  always @(posedge clk) if (rst) s <= 32'h1; else s <= c;
endmodule
