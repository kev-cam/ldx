// tb_axi.v — exercise ldx_soc_axi via AXI4-Lite master BFM.
// Stub VexRiscv, drive dBus from the bench to fake a hypercall.

`timescale 1ns/1ps

module tb_axi;

    reg aclk = 0;
    reg aresetn = 0;
    always #5 aclk = ~aclk;   // 100 MHz

    // AXI4-Lite master signals
    reg  [12:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [12:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;
    wire        hypercall_pending;

    ldx_soc_axi dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .hypercall_pending(hypercall_pending)
    );

    task axi_write(input [12:0] addr, input [31:0] data);
        begin
            @(posedge aclk);
            awaddr  <= addr;
            awvalid <= 1;
            wdata   <= data;
            wstrb   <= 4'hF;
            wvalid  <= 1;
            // Wait for both AW and W handshakes
            fork
                begin while (!awready) @(posedge aclk); @(posedge aclk); awvalid <= 0; end
                begin while (!wready)  @(posedge aclk); @(posedge aclk); wvalid  <= 0; end
            join
            bready <= 1;
            while (!bvalid) @(posedge aclk);
            @(posedge aclk);
            bready <= 0;
            if (bresp != 0) $display("[%0t] WRITE %h FAILED bresp=%b", $time, addr, bresp);
        end
    endtask

    task axi_read(input [12:0] addr, output [31:0] data);
        begin
            @(posedge aclk);
            araddr  <= addr;
            arvalid <= 1;
            while (!arready) @(posedge aclk);
            @(posedge aclk);
            arvalid <= 0;
            rready  <= 1;
            while (!rvalid) @(posedge aclk);
            data = rdata;
            @(posedge aclk);
            rready <= 0;
        end
    endtask

    reg [31:0] tmp;

    initial begin
        $dumpfile("tb_axi.vcd");
        $dumpvars(0, tb_axi);
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        repeat (4) @(posedge aclk);
        aresetn = 1;
        repeat (4) @(posedge aclk);

        // ---- 1. Magic check ----
        axi_read(13'h1F80, tmp);
        if (tmp !== 32'h4C445833) begin
            $display("FAIL: magic = %h (want 4C445833)", tmp); $finish;
        end
        $display("PASS: magic = %h", tmp);

        // ---- 2. CTRL defaults to held-in-reset ----
        axi_read(13'h1F00, tmp);
        if (tmp[0] !== 1'b1) begin
            $display("FAIL: ctrl = %h (want bit0=1)", tmp); $finish;
        end
        $display("PASS: ctrl = %h (cpu held)", tmp);

        // ---- 3. BRAM write/read while CPU held ----
        axi_write(13'h0000, 32'hDEADBEEF);
        axi_write(13'h0004, 32'hCAFEBABE);
        axi_write(13'h0FFC, 32'h12345678);
        axi_read(13'h0000, tmp);
        if (tmp !== 32'hDEADBEEF) begin $display("FAIL: ram[0]=%h", tmp); $finish; end
        axi_read(13'h0004, tmp);
        if (tmp !== 32'hCAFEBABE) begin $display("FAIL: ram[1]=%h", tmp); $finish; end
        axi_read(13'h0FFC, tmp);
        if (tmp !== 32'h12345678) begin $display("FAIL: ram[1023]=%h", tmp); $finish; end
        $display("PASS: BRAM write/read");

        // ---- 4. Mailbox: fake a CPU post via hierarchical force ----
        axi_read(13'h1F08, tmp);
        if (tmp[0] !== 1'b0) begin $display("FAIL: pending=%b before post", tmp[0]); $finish; end

        // Release CPU reset so the "cpu_rst" gate opens (delay flush + then 0)
        axi_write(13'h1F00, 32'h0);
        repeat (40) @(posedge aclk);
        $display("after release: cpu_rst=%b cpu_reset_reg=%b rst_delay=%h",
                 dut.cpu_rst, dut.cpu_reset_reg, dut.rst_delay);

        // Force dbus_cmd to post 'H' (0x48) to MBOX_DATA (0xF0000000) for one cycle
        force dut.cpu.dBus_cmd_valid           = 1'b1;
        force dut.cpu.dBus_cmd_payload_wr      = 1'b1;
        force dut.cpu.dBus_cmd_payload_address = 32'hF0000000;
        force dut.cpu.dBus_cmd_payload_data    = 32'h00000048;
        @(posedge aclk);
        // Drop valid (still forced, just to zero) so cpu_mbox_data_wr deasserts
        force dut.cpu.dBus_cmd_valid           = 1'b0;
        force dut.cpu.dBus_cmd_payload_wr      = 1'b0;

        repeat (2) @(posedge aclk);
        $display("after force: pending=%b mbox_to_ps=%h", dut.mbox_pending, dut.mbox_to_ps);
        axi_read(13'h1F08, tmp);
        if (tmp[0] !== 1'b1) begin $display("FAIL: pending=%b after post", tmp[0]); $finish; end
        $display("PASS: pending set after CPU post");
        axi_read(13'h1F04, tmp);
        if (tmp !== 32'h00000048) begin $display("FAIL: mbox_to_ps=%h", tmp); $finish; end
        $display("PASS: read mbox_to_ps = '%c'", tmp[7:0]);

        // Monitor mbox state continuously through the reply
        $display("[t=%0t] dBus_cmd_valid=%b cpu_mbox_data_wr=%b ps_mbox_data_wr=%b",
                 $time, dut.dbus_cmd_valid, dut.cpu_mbox_data_wr, dut.ps_mbox_data_wr);

        // PS replies with 0 → clears pending
        $display("[t=%0t] before reply: pending=%b", $time, dut.mbox_pending);
        axi_write(13'h1F04, 32'h00000000);
        $display("[t=%0t] after  reply: pending=%b mbox_to_cpu=%h", $time, dut.mbox_pending, dut.mbox_to_cpu);
        repeat (2) @(posedge aclk);
        $display("[t=%0t] +2 cycles  : pending=%b", $time, dut.mbox_pending);
        axi_read(13'h1F08, tmp);
        if (tmp[0] !== 1'b0) begin $display("FAIL: pending=%b after reply", tmp[0]); $finish; end
        $display("PASS: pending cleared after PS reply");

        $display("ALL PASS");
        $finish;
    end

    // Watchdog
    initial begin
        #50000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
