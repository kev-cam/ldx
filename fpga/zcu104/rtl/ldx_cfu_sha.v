// ldx_cfu_sha.v — SHA-256 specialised CFU variant.
//
// Drop-in replacement for ldx_cfu.v. Slots 0..3 carry the SHA-256 sigma
// functions used in every compression and W-expansion step. Bswap and
// bitrev8 remain at 4 and 5; the 32-cycle divider keeps 6 and 7.
//
// Functions:
//   0: vl_sha_ep0      — rotr(x,2) ^ rotr(x,13) ^ rotr(x,22)   (combi)
//   1: vl_sha_ep1      — rotr(x,6) ^ rotr(x,11) ^ rotr(x,25)   (combi)
//   2: vl_sha_sig0     — rotr(x,7) ^ rotr(x,18) ^ (x >> 3)     (combi)
//   3: vl_sha_sig1     — rotr(x,17) ^ rotr(x,19) ^ (x >> 10)   (combi)
//   4: vl_bswap32      — byte swap                              (combi)
//   5: vl_bitreverse8  — 8-bit reverse                          (combi)
//   6: divide          — sequential (32 cycles)
//   7: modulo          — sequential (32 cycles)
//
// Bus protocol: respects cmd_ready/rsp_valid handshake (so the CFU plugin
// stalls the CPU during a divide). Fast ops respond same-cycle as before.

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
    output wire [31:0] rsp_outputs_0
);
    wire [31:0] rs1 = cmd_inputs_0;
    wire [31:0] rs2 = cmd_inputs_1;
    wire        is_div = (cmd_function_id == 3'd6) || (cmd_function_id == 3'd7);
    wire        is_mod = (cmd_function_id == 3'd7);

    // -----------------------------------------------------------------
    // Combinational fast-op outputs
    // -----------------------------------------------------------------
    wire [31:0] r_ep0, r_ep1, r_sig0, r_sig1, r_bswap, r_bitrev;
    vl_sha_ep0      u0 (.x  (rs1), .result(r_ep0));
    vl_sha_ep1      u1 (.x  (rs1), .result(r_ep1));
    vl_sha_sig0     u2 (.x  (rs1), .result(r_sig0));
    vl_sha_sig1     u3 (.x  (rs1), .result(r_sig1));
    vl_bswap32      u4 (.v  (rs1), .result(r_bswap));
    vl_bitreverse8  u5 (.v  (rs1), .result(r_bitrev));

    reg [31:0] fast_result;
    always @(*) begin
        case (cmd_function_id)
            3'd0: fast_result = r_ep0;
            3'd1: fast_result = r_ep1;
            3'd2: fast_result = r_sig0;
            3'd3: fast_result = r_sig1;
            3'd4: fast_result = r_bswap;
            3'd5: fast_result = r_bitrev;
            default: fast_result = 32'd0;
        endcase
    end

    // -----------------------------------------------------------------
    // Sequential restoring divider — 32 cycles for a 32-bit divide.
    // -----------------------------------------------------------------
    reg [31:0] divisor, dividend, quotient, remainder;
    reg [5:0]  step;
    reg        div_busy, div_done, div_was_mod;

    // One restoring-division step (combinational)
    wire [32:0] sub  = {remainder[30:0], dividend[31]} - {1'b0, divisor};
    wire        take = ~sub[32];

    wire start_div = cmd_valid && is_div && !div_busy && !div_done;
    wire div_by_zero = (rs2 == 32'd0);

    always @(posedge clk) begin
        if (reset) begin
            div_busy   <= 1'b0;
            div_done   <= 1'b0;
            step       <= 6'd0;
            divisor    <= 32'd0;
            dividend   <= 32'd0;
            quotient   <= 32'd0;
            remainder  <= 32'd0;
            div_was_mod<= 1'b0;
        end else if (start_div && div_by_zero) begin
            // Match vl_div_iii: divide by zero returns 0 (1-cycle fast path)
            quotient   <= 32'd0;
            remainder  <= 32'd0;
            div_done   <= 1'b1;
            div_was_mod<= is_mod;
        end else if (start_div) begin
            divisor    <= rs2;
            dividend   <= rs1;
            quotient   <= 32'd0;
            remainder  <= 32'd0;
            step       <= 6'd32;
            div_busy   <= 1'b1;
            div_was_mod<= is_mod;
        end else if (div_busy) begin
            if (take) remainder <= sub[31:0];
            else      remainder <= {remainder[30:0], dividend[31]};
            quotient   <= {quotient[30:0], take};
            dividend   <= {dividend[30:0], 1'b0};
            step       <= step - 1'b1;
            if (step == 6'd1) begin
                div_busy <= 1'b0;
                div_done <= 1'b1;
            end
        end else if (div_done && rsp_ready) begin
            div_done <= 1'b0;
        end
    end

    wire [31:0] div_result = div_was_mod ? remainder : quotient;

    // -----------------------------------------------------------------
    // Bus protocol: fast ops respond same cycle; div stalls until done.
    // -----------------------------------------------------------------
    assign cmd_ready     = !div_busy && !div_done;
    assign rsp_valid     = div_done || (cmd_valid && !is_div && !div_busy);
    assign rsp_outputs_0 = div_done ? div_result : fast_result;

endmodule
