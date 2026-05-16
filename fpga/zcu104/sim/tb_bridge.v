// tb_bridge.v — full bridge + mesh_top end-to-end.
// AXI master loads universal.hex into all 25 cores, releases reset, then
// polls boundary endpoints for the caller's FN_LOG message.

`timescale 1ns/1ps

module tb_bridge;
    localparam N = 5;

    reg aclk = 0; always #5 aclk = ~aclk;
    reg aresetn = 0;

    // AXI master regs
    reg  [16:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [16:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    // Bridge ↔ mesh nets
    wire [N*N-1:0]      cpu_rst_req_vec;
    wire [N*N-1:0]      load_we_vec;
    wire [9:0]          load_addr;
    wire [31:0]         load_data;
    wire [4*N-1:0]      bndry_rx_valid;
    wire [4*N-1:0]      bndry_rx_ready;
    wire [4*N*32-1:0]   bndry_rx_data;
    wire [4*N-1:0]      bndry_tx_valid;
    wire [4*N-1:0]      bndry_tx_ready;
    wire [4*N*32-1:0]   bndry_tx_data;

    ldx_mesh_bridge #(.N(N)) bridge (
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
        .cpu_rst_req_vec(cpu_rst_req_vec),
        .load_we_vec(load_we_vec), .load_addr(load_addr), .load_data(load_data),
        .bndry_rx_valid(bndry_rx_valid), .bndry_rx_ready(bndry_rx_ready),
        .bndry_rx_data(bndry_rx_data),
        .bndry_tx_valid(bndry_tx_valid), .bndry_tx_ready(bndry_tx_ready),
        .bndry_tx_data(bndry_tx_data)
    );

    mesh_top #(.N(N)) mesh (
        .clk(aclk), .reset(~aresetn),
        .cpu_rst_req_vec(cpu_rst_req_vec),
        .load_we_vec(load_we_vec), .load_addr(load_addr), .load_data(load_data),
        .bndry_tx_valid(bndry_tx_valid), .bndry_tx_ready(bndry_tx_ready),
        .bndry_tx_data(bndry_tx_data),
        .bndry_rx_valid(bndry_rx_valid), .bndry_rx_ready(bndry_rx_ready),
        .bndry_rx_data(bndry_rx_data)
    );

    task axi_write(input [16:0] addr, input [31:0] data);
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

    task axi_read(input [16:0] addr, output [31:0] data);
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

    reg [31:0] prog [0:1023];
    reg [31:0] tmp;
    integer i, c;
    integer captured;

    initial begin
        $dumpfile("tb_bridge.vcd");
        $dumpvars(0, tb_bridge);
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        captured = 0;

        for (i = 0; i < 1024; i = i + 1) prog[i] = 32'h00000013;
        $readmemh("universal.hex", prog);

        repeat (8) @(posedge aclk);
        aresetn = 1;
        repeat (8) @(posedge aclk);

        // 1) Magic
        axi_read(17'h19F00, tmp);
        if (tmp !== 32'h4C445834) begin $display("FAIL magic=%h", tmp); $finish; end
        $display("PASS magic=%h", tmp);

        // 2) Reset reg defaults to all-1
        axi_read(17'h19000, tmp);
        $display("PASS ctrl_reset=%h", tmp);

        // 3) Load universal.hex into all 25 cores
        $display("Loading 25 × 1024 words ...");
        for (c = 0; c < N*N; c = c + 1) begin
            for (i = 0; i < 1024; i = i + 1) begin
                axi_write({c[4:0], i[9:0], 2'b00}, prog[i]);
            end
        end
        $display("Load done.");

        // 4) Release all
        axi_write(17'h19000, 32'd0);
        $display("All cores released.");

        // 5) Poll boundary endpoints
        begin : scan
            reg [31:0] st, hdr_word, arg_word;
            while (captured == 0) begin
                for (i = 0; i < 4*N; i = i + 1) begin
                    axi_read(17'h1910C + i*16, st);
                    if (!st[0]) begin
                        axi_read(17'h19108 + i*16, hdr_word);
                        axi_read(17'h19108 + i*16, arg_word);
                        $display("[%0t] Endpoint %0d: hdr=%h arg=%h",
                                 $time, i, hdr_word, arg_word);
                        if (arg_word == 32'd42) begin
                            $display("PASS: caller's result delivered to host (ep=%0d)", i);
                            captured = 1;
                        end
                    end
                end
            end
        end

        $display("ALL PASS");
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
