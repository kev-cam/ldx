module v4_add_a32(
  input [31:0] a1,
  input [31:0] b1,
  input [31:0] a2,
  input [31:0] b2,
  input [31:0] cin,
  output signed [31:0] result
);

  wire [31:0] xz = (b1 | b2);
  wire [31:0] sum = ((a1 + a2) + cin);

  assign result = (((a1 + a2) + cin) | (b1 | b2));

endmodule
