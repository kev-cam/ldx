// ldx_cfu_v4.v — CFU variant wiring the c2v-emitted 4-state vector gates
// from `simulators/iverilog/` for accelerating vvp's hot opcode handlers.
//
// Binary mode: the b-bit inputs (X/Z masks) are tied to 0. Vivado will
// optimize the v4_*_a32 gates down to their pure-bitwise / pure-add core
// when their X-mask inputs are constant zero. That's the right behaviour
// for binary-only workloads (SHA-256, CRC32, most synthesizable RTL).
//
// Function map (funct3):
//   0: v4_xor_a32   (rs1 ^ rs2)          — replaces vvp `of_XOR`
//   1: v4_and_a32   (rs1 & rs2)          — replaces `vvp_fun_and::run_run`
//   2: v4_or_a32    (rs1 | rs2)          — replaces `of_OR`
//   3: v4_not_a32   (~rs1)               — replaces `of_NOT`
//   4: v4_add_a32   (rs1 + rs2)          — replaces inner loop of
//                                          `vvp_arith_sum::recv_vec4`
//   5: v4_add_cout  (carry of rs1+rs2)   — for the carry chain
//   6,7: reserved   (return 0)

`timescale 1ns/1ps

module ldx_cfu (
    input  wire        clk,
    input  wire        reset,

    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [2:0]  cmd_function_id,
    input  wire [31:0] cmd_inputs_0,
    input  wire [31:0] cmd_inputs_1,

    output wire        rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_outputs_0
);
    // reset / clk not used: all gates are combinational

    wire [31:0] r_xor, r_and, r_or, r_not, r_add, r_cout;

    v4_xor_a32 u_xor (.a1(cmd_inputs_0), .b1(32'd0),
                      .a2(cmd_inputs_1), .b2(32'd0),
                      .result(r_xor));
    v4_and_a32 u_and (.a1(cmd_inputs_0), .b1(32'd0),
                      .a2(cmd_inputs_1), .b2(32'd0),
                      .result(r_and));
    v4_or_a32  u_or  (.a1(cmd_inputs_0), .b1(32'd0),
                      .a2(cmd_inputs_1), .b2(32'd0),
                      .result(r_or));
    v4_not_a32 u_not (.a(cmd_inputs_0), .b(32'd0),
                      .result(r_not));
    v4_add_a32 u_add (.a1(cmd_inputs_0), .b1(32'd0),
                      .a2(cmd_inputs_1), .b2(32'd0),
                      .cin(32'd0),
                      .result(r_add));
    v4_add_cout u_co (.a1(cmd_inputs_0), .b1(32'd0),
                      .a2(cmd_inputs_1), .b2(32'd0),
                      .cin(32'd0),
                      .result(r_cout));

    always @(*) begin
        case (cmd_function_id)
            3'd0: rsp_outputs_0 = r_xor;
            3'd1: rsp_outputs_0 = r_and;
            3'd2: rsp_outputs_0 = r_or;
            3'd3: rsp_outputs_0 = r_not;
            3'd4: rsp_outputs_0 = r_add;
            3'd5: rsp_outputs_0 = r_cout;
            default: rsp_outputs_0 = 32'd0;
        endcase
    end

    assign cmd_ready = 1'b1;
    assign rsp_valid = cmd_valid;
endmodule
