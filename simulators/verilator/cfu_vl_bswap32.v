module vl_bswap32(
  input [31:0] v,
  output signed [31:0] result
);


  assign result = (((((v & 32'd255) << 32'd24) | ((v & 32'd65280) << 32'd8)) | ((v >> 32'd8) & 32'd65280)) | ((v >> 32'd24) & 32'd255));

endmodule
