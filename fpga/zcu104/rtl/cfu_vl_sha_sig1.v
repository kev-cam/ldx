// vl_sha_sig1 — SHA-256 SIG1(x) = rotr(x,17) ^ rotr(x,19) ^ (x >> 10).
module vl_sha_sig1 (
    input  [31:0] x,
    output [31:0] result
);
    wire [31:0] r17 = {x[16:0], x[31:17]};
    wire [31:0] r19 = {x[18:0], x[31:19]};
    wire [31:0] s10 = {10'b0,   x[31:10]};
    assign result = r17 ^ r19 ^ s10;
endmodule
