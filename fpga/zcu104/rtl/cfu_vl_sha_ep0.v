// vl_sha_ep0 — SHA-256 EP0(x) = rotr(x,2) ^ rotr(x,13) ^ rotr(x,22).
// Pure combinational wiring + 32-bit XOR.
module vl_sha_ep0 (
    input  [31:0] x,
    output [31:0] result
);
    wire [31:0] r2  = {x[ 1:0], x[31: 2]};
    wire [31:0] r13 = {x[12:0], x[31:13]};
    wire [31:0] r22 = {x[21:0], x[31:22]};
    assign result = r2 ^ r13 ^ r22;
endmodule
