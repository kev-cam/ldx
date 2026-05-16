// tb_cfu_e2e.v — full SoC + real CFU: load cfu_test.bin, expect 9 mailbox
// posts matching the C source's commented goldens.

`timescale 1ns/1ps

module tb_cfu_e2e;

    reg aclk = 0;
    reg aresetn = 0;
    always #5 aclk = ~aclk;

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

    integer i, fails;
    reg [31:0] tmp;
    reg [31:0] prog [0:1023];
    reg [31:0] got [0:8];
    reg [31:0] gold [0:8];

    initial begin
        $dumpfile("tb_cfu_e2e.vcd");
        $dumpvars(0, tb_cfu_e2e);
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        fails = 0;
        for (i = 0; i < 1024; i = i + 1) prog[i] = 32'h00000013;
        $readmemh("cfu_test.hex", prog);

        // Expected results (match comments in cfu_test.c)
        gold[0] = 24;             // popcount(0xDEADBEEF)
        gold[1] = 0;              // parity(0xDEADBEEF)
        gold[2] = 1;              // onehot(0x10)
        gold[3] = 0;              // onehot0(0x3)
        gold[4] = 32'h44332211;   // bswap(0x11223344)
        gold[5] = 32'h000000A5;   // bitrev8(0xA5)
        gold[6] = 14;             // 100/7
        gold[7] = 2;              // 100%7
        gold[8] = 0;              // safe div by 0

        repeat (4) @(posedge aclk);
        aresetn = 1;
        repeat (4) @(posedge aclk);

        for (i = 0; i < 256; i = i + 1) axi_write(i*4, prog[i]);
        axi_write(13'h1F00, 32'h0);

        for (i = 0; i < 9; i = i + 1) begin : capture
            integer wait_count;
            wait_count = 0;
            forever begin
                axi_read(13'h1F08, tmp);
                if (tmp[0]) begin
                    axi_read(13'h1F04, got[i]);
                    axi_write(13'h1F04, 32'h0);
                    if (got[i] === gold[i])
                        $display("PASS[%0d] got=0x%08h", i, got[i]);
                    else begin
                        $display("FAIL[%0d] got=0x%08h want=0x%08h", i, got[i], gold[i]);
                        fails = fails + 1;
                    end
                    disable capture;
                end
                wait_count = wait_count + 1;
                if (wait_count > 10000) begin
                    $display("TIMEOUT waiting for post %0d", i);
                    fails = fails + 1;
                    disable capture;
                end
            end
        end

        if (fails == 0) $display("ALL PASS");
        else            $display("FAIL: %0d mismatches", fails);
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish; end

endmodule
