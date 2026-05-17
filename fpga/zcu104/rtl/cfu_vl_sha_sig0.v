// vl_sha_sig0 — SHA-256 SIG0(x) = rotr(x,7) ^ rotr(x,18) ^ (x >> 3).
module vl_sha_sig0 (
    input  [31:0] x,
    output [31:0] result
);
    wire [31:0] r7  = {x[ 6:0], x[31: 7]};
    wire [31:0] r18 = {x[17:0], x[31:18]};
    wire [31:0] s3  = {3'b000,  x[31: 3]};
    assign result = r7 ^ r18 ^ s3;
endmodule
