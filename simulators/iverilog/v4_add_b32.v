module v4_add_b32(
  input [31:0] a1,
  input [31:0] b1,
  input [31:0] a2,
  input [31:0] b2,
  input [31:0] cin,
  output signed [31:0] result
);

  wire [31:0] any = (b1 | b2);
  wire [31:0] mask = (((b1 | b2) != 32'd0) ? 32'hFFFFFFFF : 32'd0);

  assign result = (((b1 | b2) != 32'd0) ? 32'hFFFFFFFF : 32'd0);

endmodule
