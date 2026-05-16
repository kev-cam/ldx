// tb_mesh55.v — 5×5 mesh, all cores run universal.hex.
// Core (1,1) is the caller: wander_call FN_DOUBLE(21) on (5,5), expects 42.
// All 20 boundary ports tied off (no host traffic).

`timescale 1ns/1ps

module tb_mesh55;
    localparam N = 5;
    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;
    reg [N*N-1:0] cpu_rst_req_vec;

    wire [4*N-1:0]    bndry_tx_valid;
    reg  [4*N-1:0]    bndry_tx_ready;
    wire [4*N*32-1:0] bndry_tx_data;
    reg  [4*N-1:0]    bndry_rx_valid;
    wire [4*N-1:0]    bndry_rx_ready;
    reg  [4*N*32-1:0] bndry_rx_data;

    mesh_top #(.N(N)) dut (
        .clk(clk), .reset(reset),
        .cpu_rst_req_vec(cpu_rst_req_vec),
        .load_we_vec({(N*N){1'b0}}),
        .load_addr(10'd0),
        .load_data(32'd0),
        .bndry_tx_valid(bndry_tx_valid), .bndry_tx_ready(bndry_tx_ready),
        .bndry_tx_data(bndry_tx_data),
        .bndry_rx_valid(bndry_rx_valid), .bndry_rx_ready(bndry_rx_ready),
        .bndry_rx_data(bndry_rx_data)
    );

    integer gx, gy, i;
    initial begin
        $dumpfile("tb_mesh55.vcd");
        $dumpvars(0, tb_mesh55);

        // Tie off all 20 boundary ports
        bndry_tx_ready = {(4*N){1'b1}};   // host always ready to receive
        bndry_rx_valid = {(4*N){1'b0}};   // host sends nothing
        bndry_rx_data  = {(4*N*32){1'b0}};
        cpu_rst_req_vec = {(N*N){1'b1}};   // all cores held in reset

        // Load every core with universal.hex (the .hex is padded to 1024 words)
        $readmemh("universal.hex", dut.gx_loop[0].gy_loop[0].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[0].gy_loop[1].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[0].gy_loop[2].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[0].gy_loop[3].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[0].gy_loop[4].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[1].gy_loop[0].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[1].gy_loop[1].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[1].gy_loop[2].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[1].gy_loop[3].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[1].gy_loop[4].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[2].gy_loop[0].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[2].gy_loop[1].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[2].gy_loop[2].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[2].gy_loop[3].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[2].gy_loop[4].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[3].gy_loop[0].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[3].gy_loop[1].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[3].gy_loop[2].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[3].gy_loop[3].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[3].gy_loop[4].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[4].gy_loop[0].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[4].gy_loop[1].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[4].gy_loop[2].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[4].gy_loop[3].core.dpram);
        $readmemh("universal.hex", dut.gx_loop[4].gy_loop[4].core.dpram);

        repeat (4) @(posedge clk);
        reset = 0;
        repeat (20) @(posedge clk);
        cpu_rst_req_vec = {(N*N){1'b0}};
    end

    // Caller is at logical (1,1) = array indices (0,0)
    initial begin
        wait (dut.gx_loop[0].gy_loop[0].core.dpram[1023] == 32'd42);
        $display("[%0t] PASS: caller @(1,1) got wander_call return = 42", $time);
        $display("ALL PASS");
        $finish;
    end

    initial begin
        #50000000;          // 50 ms sim time
        $display("TIMEOUT: a[1023]=%h", dut.gx_loop[0].gy_loop[0].core.dpram[1023]);
        $finish;
    end
endmodule
