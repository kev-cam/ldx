// tb_soc.v — Testbench for ldx_soc: VexRiscv runs a tiny program.
`timescale 1ns/1ps

module tb_soc;
    reg clk = 0;
    reg reset = 1;

    // Avalon-MM slave (PCIe side)
    reg  [10:0] address = 0;
    reg         avs_read = 0;
    reg         avs_write = 0;
    reg  [31:0] writedata = 0;
    wire [31:0] readdata;
    reg  [3:0]  byteenable = 4'hF;
    reg         chipselect = 0;

    always #4 clk = ~clk;  // 125 MHz

    ldx_soc dut (
        .clk(clk), .reset(reset), .reset_req(1'b0),
        .address(address), .read(avs_read), .write(avs_write),
        .readdata(readdata), .writedata(writedata),
        .byteenable(byteenable), .chipselect(chipselect)
    );

    // Write a word to RAM via "PCIe"
    task pcie_write(input [10:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            address = addr; writedata = data; avs_write = 1; chipselect = 1;
            @(posedge clk);
            avs_write = 0; chipselect = 0;
        end
    endtask

    // Read a word via "PCIe"
    task pcie_read(input [10:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            address = addr; avs_read = 1; chipselect = 1;
            @(posedge clk);
            data = readdata;
            avs_read = 0; chipselect = 0;
        end
    endtask

    reg [31:0] val;
    integer i;

    // Tiny test program: write 42 to IO_RESULT0, 99 to IO_RESULT1, set done
    // _start at 0x80000000:
    //   lui a5, 0xF0000       # a5 = 0xF0000000
    //   li  a4, 42            # a4 = 42
    //   sw  a4, 0(a5)         # IO_RESULT0 = 42
    //   li  a4, 99
    //   sw  a4, 8(a5)         # IO_RESULT1 = 99
    //   li  a4, 1
    //   sw  a4, 4(a5)         # IO_DONE = 1
    //   j   .                 # halt
    //
    // Machine code (rv32im):
    reg [31:0] prog [0:7];
    initial begin
        prog[0] = 32'hF00007B7;  // lui a5, 0xF0000
        prog[1] = 32'h02A00713;  // li a4, 42
        prog[2] = 32'h00E7A023;  // sw a4, 0(a5)
        prog[3] = 32'h06300713;  // li a4, 99
        prog[4] = 32'h00E7A423;  // sw a4, 8(a5)
        prog[5] = 32'h00100713;  // li a4, 1
        prog[6] = 32'h00E7A223;  // sw a4, 4(a5)
        prog[7] = 32'h0000006F;  // j .  (infinite loop)
    end

    initial begin
        $dumpfile("tb_soc.vcd");
        $dumpvars(0, tb_soc);

        // Hold reset
        reset = 1;
        #100;
        reset = 0;
        #20;

        // CPU should be in reset (cpu_reset_reg=1 after reset)
        // Load program via PCIe
        for (i = 0; i < 8; i = i + 1) begin
            pcie_write(i, prog[i]);
        end

        // Verify RAM loaded
        pcie_read(0, val);
        if (val !== 32'hF00007B7) begin
            $display("FAIL: RAM[0] = 0x%08X (expected 0xF00007B7)", val);
            $finish;
        end
        $display("RAM loaded OK");

        // Check magic
        pcie_read(11'h7E0, val);
        $display("Magic: 0x%08X (%s)", val, val == 32'h4C445832 ? "LDX2" : "WRONG");

        // Release CPU (write 0 to control register 0x7C0)
        pcie_write(11'h7C0, 32'h0);
        $display("CPU released");

        // Wait for CPU to execute (give it lots of cycles)
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk);
        end

        // Check done
        pcie_read(11'h7C1, val);
        $display("Done: %0d", val);

        // Read results
        pcie_read(11'h7C2, val);
        $display("Result[0] = %0d (expected 42)  %s", val, val == 42 ? "PASS" : "FAIL");

        pcie_read(11'h7C3, val);
        $display("Result[1] = %0d (expected 99)  %s", val, val == 99 ? "PASS" : "FAIL");

        $finish;
    end

    // Timeout
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
