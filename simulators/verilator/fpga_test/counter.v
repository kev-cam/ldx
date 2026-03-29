// counter.v — Trivial 8-bit counter for Verilator-on-FPGA test.
module counter (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,
    output reg  [7:0] count,
    output wire       overflow
);
    assign overflow = (count == 8'hFF) & enable;
    always @(posedge clk) begin
        if (reset)
            count <= 8'd0;
        else if (enable)
            count <= count + 8'd1;
    end
endmodule
