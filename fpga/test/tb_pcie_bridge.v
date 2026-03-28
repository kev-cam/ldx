// tb_pcie_bridge.v — Test PCIe bridge → accel_slot → add.
`timescale 1ns/1ps

module tb_pcie_bridge;
    reg         clk = 0;
    reg         reset_n = 0;
    reg  [12:0] pcie_address;
    reg         pcie_read;
    reg         pcie_write;
    reg  [31:0] pcie_writedata;
    reg  [3:0]  pcie_byteenable;
    wire [31:0] pcie_readdata;
    wire        pcie_waitrequest;

    always #4 clk = ~clk;

    // Slot 0 wires
    wire [5:0]  s0_addr;
    wire        s0_read, s0_write;
    wire [31:0] s0_wdata, s0_rdata;
    wire        s0_wait;

    pcie_bar_bridge #(.N_SLOTS(1)) u_bridge (
        .clk(clk), .reset_n(reset_n),
        .pcie_address(pcie_address), .pcie_read(pcie_read),
        .pcie_write(pcie_write), .pcie_writedata(pcie_writedata),
        .pcie_byteenable(pcie_byteenable), .pcie_readdata(pcie_readdata),
        .pcie_waitrequest(pcie_waitrequest),
        .slot0_address(s0_addr), .slot0_read(s0_read),
        .slot0_write(s0_write), .slot0_writedata(s0_wdata),
        .slot0_readdata(s0_rdata), .slot0_waitrequest(s0_wait)
    );

    accel_slot #(.N_ARGS(2), .RET_WIDTH(32)) u_slot0 (
        .clk(clk), .reset_n(reset_n),
        .avs_address(s0_addr), .avs_read(s0_read),
        .avs_write(s0_write), .avs_writedata(s0_wdata),
        .avs_readdata(s0_rdata), .avs_waitrequest(s0_wait)
    );

    integer pass = 0, fail = 0;

    // Write to byte address in BAR0
    task bar_write(input [12:0] addr, input [31:0] val);
        begin
            @(posedge clk);
            pcie_address = addr; pcie_writedata = val;
            pcie_write = 1; pcie_read = 0; pcie_byteenable = 4'hF;
            @(posedge clk);
            pcie_write = 0;
        end
    endtask

    task bar_read(input [12:0] addr, output [31:0] val);
        begin
            @(posedge clk);
            pcie_address = addr; pcie_read = 1; pcie_write = 0;
            @(posedge clk);
            val = pcie_readdata;
            pcie_read = 0;
        end
    endtask

    task test_via_pcie(input [31:0] a, input [31:0] b, input [31:0] expected);
        reg [31:0] result, magic;
        begin
            // Write args to slot 0: offset 0x00 and 0x04
            bar_write(13'h000, a);
            bar_write(13'h004, b);
            // Read result from slot 0: offset 0x40
            bar_read(13'h040, result);
            if (result === expected) begin
                $display("PASS: pcie add(%0d, %0d) = %0d", a, b, result);
                pass = pass + 1;
            end else begin
                $display("FAIL: pcie add(%0d, %0d) = %0d (expected %0d)", a, b, result, expected);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        reset_n = 0;
        pcie_address = 0; pcie_read = 0; pcie_write = 0;
        pcie_writedata = 0; pcie_byteenable = 4'hF;
        #20;
        reset_n = 1;
        #10;

        // Test global registers
        begin
            reg [31:0] val;
            bar_read(13'h1F00, val);
            if (val === 32'h4C445831) begin
                $display("PASS: magic = LDX1");
                pass = pass + 1;
            end else begin
                $display("FAIL: magic = 0x%08X", val);
                fail = fail + 1;
            end

            bar_read(13'h1F04, val);
            if (val === 32'h00010000) begin
                $display("PASS: version = 1.0.0");
                pass = pass + 1;
            end else begin
                $display("FAIL: version = 0x%08X", val);
                fail = fail + 1;
            end

            bar_read(13'h1F08, val);
            if (val === 32'd1) begin
                $display("PASS: n_slots = 1");
                pass = pass + 1;
            end else begin
                $display("FAIL: n_slots = %0d", val);
                fail = fail + 1;
            end
        end

        // Test function calls via PCIe BAR
        test_via_pcie(0, 0, 0);
        test_via_pcie(3, 7, 10);
        test_via_pcie(100, 200, 300);
        test_via_pcie(32'hFFFFFFFF, 1, 0);

        #10;
        $display("\n%0d passed, %0d failed", pass, fail);
        if (fail > 0) $finish;
        $display("ALL TESTS PASSED");
        $finish;
    end
endmodule
