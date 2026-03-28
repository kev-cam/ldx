// tb_accel_slot.v — Testbench for accel_slot + add function.
`timescale 1ns/1ps

module tb_accel_slot;
    reg         clk = 0;
    reg         reset_n = 0;
    reg  [5:0]  address;
    reg         read;
    reg         write;
    reg  [31:0] writedata;
    wire [31:0] readdata;
    wire        waitrequest;

    always #4 clk = ~clk;  // 125 MHz

    accel_slot #(.N_ARGS(2), .RET_WIDTH(32)) dut (
        .clk(clk), .reset_n(reset_n),
        .avs_address(address), .avs_read(read), .avs_write(write),
        .avs_writedata(writedata), .avs_readdata(readdata),
        .avs_waitrequest(waitrequest)
    );

    integer pass = 0, fail = 0;

    task write_reg(input [5:0] addr, input [31:0] val);
        begin
            @(posedge clk);
            address = addr; writedata = val; write = 1; read = 0;
            @(posedge clk);
            write = 0;
        end
    endtask

    task read_reg(input [5:0] addr, output [31:0] val);
        begin
            @(posedge clk);
            address = addr; read = 1; write = 0;
            @(posedge clk);
            val = readdata;
            read = 0;
        end
    endtask

    task test_add(input [31:0] a, input [31:0] b, input [31:0] expected);
        reg [31:0] result;
        begin
            write_reg(0, a);   // arg_reg[0] = a
            write_reg(1, b);   // arg_reg[1] = b
            read_reg(6'h10, result);  // read result (0x40 >> 2 = 0x10)
            if (result === expected) begin
                $display("PASS: add(%0d, %0d) = %0d", a, b, result);
                pass = pass + 1;
            end else begin
                $display("FAIL: add(%0d, %0d) = %0d (expected %0d)", a, b, result, expected);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        reset_n = 0;
        address = 0; read = 0; write = 0; writedata = 0;
        #20;
        reset_n = 1;
        #10;

        test_add(0, 0, 0);
        test_add(1, 2, 3);
        test_add(42, 58, 100);
        test_add(100, -1, 99);
        test_add(32'h7FFFFFFF, 1, 32'h80000000);
        test_add(32'hDEADBEEF, 32'h11111111, 32'hEFBED000);

        #10;
        $display("\n%0d passed, %0d failed", pass, fail);
        if (fail > 0) $finish;
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
