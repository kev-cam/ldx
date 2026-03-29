module vl_moddiv_iii(
  input [31:0] lhs,
  input [31:0] rhs,
  output signed [31:0] result
);


  assign result = (rhs ? (lhs % rhs) : 32'd0);

endmodule
