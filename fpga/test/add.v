// add.v — Hand-written c2v-equivalent for testing.
module add (
    input  wire signed [31:0] a,
    input  wire signed [31:0] b,
    output wire signed [31:0] result
);
    assign result = (a + b);
endmodule
