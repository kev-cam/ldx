// tb_cfu.v — Testbench for ldx CFU (Custom Function Unit).
`timescale 1ns/1ps

module tb_cfu;
    reg         clk = 0;
    reg         reset = 1;
    reg         cmd_valid = 0;
    wire        cmd_ready;
    reg  [9:0]  cmd_function_id;
    reg  [31:0] cmd_inputs_0;
    reg  [31:0] cmd_inputs_1;
    wire        rsp_valid;
    reg         rsp_ready = 1;
    wire [31:0] rsp_outputs_0;

    always #4 clk = ~clk;

    ldx_cfu dut (
        .clk(clk), .reset(reset),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_function_id(cmd_function_id),
        .cmd_inputs_0(cmd_inputs_0), .cmd_inputs_1(cmd_inputs_1),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_outputs_0(rsp_outputs_0)
    );

    integer pass = 0, fail = 0;

    task test_cfu(
        input [9:0]  func_id,
        input [31:0] rs1,
        input [31:0] rs2,
        input [31:0] expected,
        input [255:0] name  // 32-char string
    );
        begin
            @(posedge clk);
            cmd_valid = 1;
            cmd_function_id = func_id;
            cmd_inputs_0 = rs1;
            cmd_inputs_1 = rs2;
            @(posedge clk);
            cmd_valid = 0;
            #1;
            if (rsp_outputs_0 === expected) begin
                pass = pass + 1;
            end else begin
                $display("FAIL %0s(%0d, %0d) = %0d (expected %0d)",
                         name, rs1, rs2, rsp_outputs_0, expected);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        reset = 1; #20; reset = 0; #10;

        // func 0: countones (popcount)
        test_cfu(0, 32'h00000000, 0, 0,  "countones");
        test_cfu(0, 32'h00000001, 0, 1,  "countones");
        test_cfu(0, 32'h0000FFFF, 0, 16, "countones");
        test_cfu(0, 32'hFFFFFFFF, 0, 32, "countones");
        test_cfu(0, 32'hAAAAAAAA, 0, 16, "countones");
        test_cfu(0, 32'h80000001, 0, 2,  "countones");

        // func 1: redxor (parity)
        test_cfu(1, 32'h00000000, 0, 0, "redxor");
        test_cfu(1, 32'h00000001, 0, 1, "redxor");
        test_cfu(1, 32'h00000003, 0, 0, "redxor");
        test_cfu(1, 32'h00000007, 0, 1, "redxor");
        test_cfu(1, 32'hFFFFFFFF, 0, 0, "redxor");

        // func 2: onehot
        test_cfu(2, 32'h00000000, 0, 0, "onehot");
        test_cfu(2, 32'h00000001, 0, 1, "onehot");
        test_cfu(2, 32'h00000010, 0, 1, "onehot");
        test_cfu(2, 32'h80000000, 0, 1, "onehot");
        test_cfu(2, 32'h00000003, 0, 0, "onehot");

        // func 3: onehot0
        test_cfu(3, 32'h00000000, 0, 1, "onehot0");
        test_cfu(3, 32'h00000001, 0, 1, "onehot0");
        test_cfu(3, 32'h00000003, 0, 0, "onehot0");

        // func 4: bswap32
        test_cfu(4, 32'h12345678, 0, 32'h78563412, "bswap32");
        test_cfu(4, 32'hDEADBEEF, 0, 32'hEFBEADDE, "bswap32");

        // func 5: bitreverse8
        test_cfu(5, 32'h00000001, 0, 32'h00000080, "bitrev8");
        test_cfu(5, 32'h000000FF, 0, 32'h000000FF, "bitrev8");
        test_cfu(5, 32'h000000A5, 0, 32'h000000A5, "bitrev8");

        // func 6: div (safe, returns 0 for div-by-zero)
        test_cfu(6, 100, 10, 10, "div");
        test_cfu(6, 100,  0,  0, "div");  // div by zero
        test_cfu(6,   7,  2,  3, "div");

        // func 7: moddiv
        test_cfu(7, 100, 10,  0, "mod");
        test_cfu(7, 100,  0,  0, "mod");  // mod by zero
        test_cfu(7,   7,  2,  1, "mod");

        #10;
        $display("%0d passed, %0d failed", pass, fail);
        if (fail == 0) $display("CFU ALL PASS");
        $finish;
    end
endmodule
