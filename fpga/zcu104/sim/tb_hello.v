// tb_hello.v — full SoC sim: real VexRiscv runs hello.c, sim acts as PS daemon.

`timescale 1ns/1ps

module tb_hello;

    reg aclk = 0;
    reg aresetn = 0;
    always #5 aclk = ~aclk;   // 100 MHz

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
            awaddr  <= addr; awvalid <= 1;
            wdata   <= data; wstrb   <= 4'hF; wvalid <= 1;
            fork
                begin while (!awready) @(posedge aclk); @(posedge aclk); awvalid <= 0; end
                begin while (!wready)  @(posedge aclk); @(posedge aclk); wvalid  <= 0; end
            join
            bready <= 1;
            while (!bvalid) @(posedge aclk);
            @(posedge aclk);
            bready <= 0;
        end
    endtask

    task axi_read(input [12:0] addr, output [31:0] data);
        begin
            @(posedge aclk);
            araddr  <= addr; arvalid <= 1;
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

    integer i;
    reg [31:0] tmp;
    reg [31:0] prog [0:1023];
    integer captured;
    reg [7:0] out_buf [0:255];

    initial begin
        $dumpfile("tb_hello.vcd");
        $dumpvars(0, tb_hello);
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        captured = 0;
        for (i = 0; i < 1024; i = i + 1) prog[i] = 32'h00000013;  // nop fill
        $readmemh("hello.hex", prog);

        repeat (4) @(posedge aclk);
        aresetn = 1;
        repeat (4) @(posedge aclk);

        // Sanity check magic
        axi_read(13'h1F80, tmp);
        if (tmp !== 32'h4C445833) begin $display("FAIL: magic=%h", tmp); $finish; end

        // Load program into BRAM via AXI (CPU is held in reset)
        $display("Loading %0d words into BRAM...", $size(prog,1));
        for (i = 0; i < 64; i = i + 1) begin    // first 64 words enough for hello
            axi_write(i*4, prog[i]);
        end
        $display("Program loaded.");

        // Release CPU
        axi_write(13'h1F00, 32'h0);
        $display("CPU released.");

        // PS daemon loop: poll mailbox status, when pending, read data,
        // print char, reply with 0.
        while (captured < 6) begin
            axi_read(13'h1F08, tmp);
            if (tmp[0]) begin
                axi_read(13'h1F04, tmp);
                out_buf[captured] = tmp[7:0];
                $display("[%0t] PS got '%c' (0x%02h)", $time, tmp[7:0], tmp[7:0]);
                captured = captured + 1;
                axi_write(13'h1F04, 32'h0);   // reply, clears pending
            end
        end

        $display("Captured 6 chars: %c%c%c%c%c%c",
                 out_buf[0], out_buf[1], out_buf[2], out_buf[3], out_buf[4], out_buf[5]);
        if (out_buf[0]=="H" && out_buf[1]=="e" && out_buf[2]=="l"
            && out_buf[3]=="l" && out_buf[4]=="o" && out_buf[5]=="\n")
            $display("PASS: hello received");
        else
            $display("FAIL: bad chars");
        $finish;
    end

    // Watchdog
    initial begin
        #500000;
        $display("TIMEOUT — captured=%0d", captured);
        $finish;
    end

endmodule
