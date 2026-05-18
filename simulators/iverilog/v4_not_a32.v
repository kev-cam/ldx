module v4_not_a32(
  input [31:0] a,
  input [31:0] b,
  output signed [31:0] result
);


  assign result = ((~a) | b);

endmodule
