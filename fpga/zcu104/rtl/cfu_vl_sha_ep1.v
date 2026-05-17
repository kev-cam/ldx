// vl_sha_ep1 — SHA-256 EP1(x) = rotr(x,6) ^ rotr(x,11) ^ rotr(x,25).
module vl_sha_ep1 (
    input  [31:0] x,
    output [31:0] result
);
    wire [31:0] r6  = {x[ 5:0], x[31: 6]};
    wire [31:0] r11 = {x[10:0], x[31:11]};
    wire [31:0] r25 = {x[24:0], x[31:25]};
    assign result = r6 ^ r11 ^ r25;
endmodule
