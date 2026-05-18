module v4_and_b32(
  input [31:0] a1,
  input [31:0] b1,
  input [31:0] a2,
  input [31:0] b2,
  output signed [31:0] result
);

  wire [31:0] tmp1 = (a1 | b1);
  wire [31:0] tmp2 = (a2 | b2);

  assign result = (((a1 | b1) & b2) | ((a2 | b2) & b1));

endmodule
