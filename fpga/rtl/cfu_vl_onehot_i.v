module vl_onehot_i(
  input [31:0] lhs,
  output signed [31:0] result
);


  assign result = (((lhs & (lhs - 32'd1)) == 32'd0) & (lhs != 32'd0));

endmodule
