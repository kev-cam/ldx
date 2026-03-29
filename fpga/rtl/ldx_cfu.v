// ldx_cfu.v — Custom Function Unit for VexRiscv.
//
// Connects to VexRiscv's CfuPlugin bus and dispatches CUSTOM_0
// instructions to c2v-generated combinational modules.
//
// Interface: CFU bus (Stream cmd/rsp)
//   cmd_valid, cmd_ready, cmd_function_id[9:0], cmd_inputs_0[31:0], cmd_inputs_1[31:0]
//   rsp_valid, rsp_ready, rsp_outputs_0[31:0]
//
// RISC-V encoding: custom0 rd, rs1, rs2
//   opcode = 0001011
//   function_id = {funct7[6:0], funct3[2:0]}
//
// Function map (from Verilator runtime primitives):
//   0: vl_countones_i(rs1) — population count
//   1: vl_redxor_32(rs1)   — reduction XOR (parity)
//   2: vl_onehot_i(rs1)    — one-hot check
//   3: vl_onehot0_i(rs1)   — one-hot-or-zero check
//   4: vl_bswap32(rs1)     — byte swap
//   5: vl_bitreverse8(rs1) — 8-bit reverse
//   6: vl_div_iii(rs1,rs2) — safe divide (0 on div-by-zero)
//   7: vl_moddiv_iii(rs1,rs2) — safe modulo

module ldx_cfu (
    input  wire        clk,
    input  wire        reset,

    // CFU command (from VexRiscv)
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire [2:0]  cmd_function_id,
    input  wire [31:0] cmd_inputs_0,    // rs1
    input  wire [31:0] cmd_inputs_1,    // rs2

    // CFU response (to VexRiscv)
    output wire        rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_outputs_0    // rd
);

    wire [31:0] rs1 = cmd_inputs_0;
    wire [31:0] rs2 = cmd_inputs_1;

    // All functions are single-cycle combinational
    assign cmd_ready = rsp_ready;
    assign rsp_valid = cmd_valid;

    // ---- Function outputs ----
    wire [31:0] countones_result;
    wire [31:0] redxor_result;
    wire [31:0] onehot_result;
    wire [31:0] onehot0_result;
    wire [31:0] bswap_result;
    wire [31:0] bitrev_result;
    wire [31:0] div_result;
    wire [31:0] mod_result;

    // ---- c2v module instances ----

    // 0: popcount
    vl_countones_i u_countones(.lhs(rs1), .result(countones_result));

    // 1: reduction XOR (parity)
    vl_redxor_32 u_redxor(.r(rs1), .result(redxor_result));

    // 2: one-hot
    vl_onehot_i u_onehot(.lhs(rs1), .result(onehot_result));

    // 3: one-hot-or-zero
    vl_onehot0_i u_onehot0(.lhs(rs1), .result(onehot0_result));

    // 4: byte swap
    vl_bswap32 u_bswap(.v(rs1), .result(bswap_result));

    // 5: bit reverse 8
    vl_bitreverse8 u_bitrev(.v(rs1), .result(bitrev_result));

    // 6: safe divide
    vl_div_iii u_div(.lhs(rs1), .rhs(rs2), .result(div_result));

    // 7: safe modulo
    vl_moddiv_iii u_mod(.lhs(rs1), .rhs(rs2), .result(mod_result));

    // ---- Function select MUX ----
    always @(*) begin
        case (cmd_function_id)
            3'd0:    rsp_outputs_0 = countones_result;
            3'd1:    rsp_outputs_0 = redxor_result;
            3'd2:    rsp_outputs_0 = onehot_result;
            3'd3:    rsp_outputs_0 = onehot0_result;
            3'd4:    rsp_outputs_0 = bswap_result;
            3'd5:    rsp_outputs_0 = bitrev_result;
            3'd6:    rsp_outputs_0 = div_result;
            3'd7:    rsp_outputs_0 = mod_result;
        endcase
    end

endmodule
