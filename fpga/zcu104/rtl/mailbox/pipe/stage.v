// one pipeline stage: registered increment (a trivial but real accel-C stage)
module stage(input clk, input rst, input [31:0] din, output reg [31:0] dout);
  always @(posedge clk) if (rst) dout <= 0; else dout <= din + 1;
endmodule
