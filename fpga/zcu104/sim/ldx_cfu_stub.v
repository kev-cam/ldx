// Minimal CFU stub for hello-world sim (real ldx_cfu.v needs c2v's vl_* primitives)
`timescale 1ns/1ps
module ldx_cfu (
    input  wire        clk, reset,
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [2:0]  cmd_function_id,
    input  wire [31:0] cmd_inputs_0, cmd_inputs_1,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_outputs_0
);
    assign cmd_ready = 1'b1;
    always @(posedge clk) begin
        if (reset) begin
            rsp_valid <= 0;
            rsp_outputs_0 <= 0;
        end else begin
            rsp_valid <= cmd_valid;
            rsp_outputs_0 <= cmd_inputs_0 + cmd_inputs_1;
        end
    end
endmodule
