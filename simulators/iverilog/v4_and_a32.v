module v4_and_a32(
  input [31:0] a1,
  input [31:0] b1,
  input [31:0] a2,
  input [31:0] b2,
  output signed [31:0] result
);


  assign result = ((a1 | b1) & (a2 | b2));

endmodule
