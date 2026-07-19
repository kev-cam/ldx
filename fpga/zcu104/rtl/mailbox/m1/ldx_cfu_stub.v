// minimal ldx_cfu stub for the M1 mailbox sim (worker never issues CFU ops)
module ldx_cfu(
  input clk, input reset,
  input cmd_valid, output cmd_ready,
  input [2:0] cmd_function_id, input [31:0] cmd_inputs_0, input [31:0] cmd_inputs_1,
  output rsp_valid, input rsp_ready, output [31:0] rsp_outputs_0);
  assign cmd_ready = 1'b1;
  assign rsp_valid = cmd_valid;     // single-cycle ack
  assign rsp_outputs_0 = 32'd0;
endmodule
