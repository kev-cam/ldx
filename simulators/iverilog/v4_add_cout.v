module v4_add_cout(
  input [31:0] a1,
  input [31:0] b1,
  input [31:0] a2,
  input [31:0] b2,
  input [31:0] cin,
  output signed [31:0] result
);

  wire [63:0] s = ((a1 + a2) + cin);
  wire [63:0] _cast_1 = (((a1 + a2) + cin) >> 32'd32);

  assign result = _cast_1[31:0];

endmodule
