// tb_wc.v — wander_call across two cores.
// (0,0) calls FN_DOUBLE(21) on (1,0); expects 42 in its RESULT.

`timescale 1ns/1ps

module tb_wc;
    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;
    reg cpu_rst_req = 1;

    wire [3:0]   a_tx_valid, a_tx_ready;
    wire [127:0] a_tx_data;
    wire [3:0]   a_rx_valid, a_rx_ready;
    wire [127:0] a_rx_data;

    wire [3:0]   b_tx_valid, b_tx_ready;
    wire [127:0] b_tx_data;
    wire [3:0]   b_rx_valid, b_rx_ready;
    wire [127:0] b_rx_data;

    // A.E ↔ B.W
    assign b_rx_valid[3]      = a_tx_valid[1];
    assign b_rx_data[127:96]  = a_tx_data[63:32];
    assign a_tx_ready[1]      = b_rx_ready[3];

    assign a_rx_valid[1]      = b_tx_valid[3];
    assign a_rx_data[63:32]   = b_tx_data[127:96];
    assign b_tx_ready[3]      = a_rx_ready[1];

    assign a_tx_ready[0] = 1'b1; assign a_tx_ready[2] = 1'b1; assign a_tx_ready[3] = 1'b1;
    assign a_rx_valid[0] = 1'b0; assign a_rx_data[31:0]   = 32'd0;
    assign a_rx_valid[2] = 1'b0; assign a_rx_data[95:64]  = 32'd0;
    assign a_rx_valid[3] = 1'b0; assign a_rx_data[127:96] = 32'd0;

    assign b_tx_ready[0] = 1'b1; assign b_tx_ready[1] = 1'b1; assign b_tx_ready[2] = 1'b1;
    assign b_rx_valid[0] = 1'b0; assign b_rx_data[31:0]   = 32'd0;
    assign b_rx_valid[1] = 1'b0; assign b_rx_data[63:32]  = 32'd0;
    assign b_rx_valid[2] = 1'b0; assign b_rx_data[95:64]  = 32'd0;

    ldx_soc_mesh #(.MY_X(0), .MY_Y(0)) core_a (
        .clk(clk), .reset(reset),
        .load_we(1'b0), .load_addr(10'd0), .load_data(32'd0),
        .cpu_rst_req(cpu_rst_req),
        .tx_valid(a_tx_valid), .tx_ready(a_tx_ready), .tx_data(a_tx_data),
        .rx_valid(a_rx_valid), .rx_ready(a_rx_ready), .rx_data(a_rx_data)
    );

    ldx_soc_mesh #(.MY_X(1), .MY_Y(0)) core_b (
        .clk(clk), .reset(reset),
        .load_we(1'b0), .load_addr(10'd0), .load_data(32'd0),
        .cpu_rst_req(cpu_rst_req),
        .tx_valid(b_tx_valid), .tx_ready(b_tx_ready), .tx_data(b_tx_data),
        .rx_valid(b_rx_valid), .rx_ready(b_rx_ready), .rx_data(b_rx_data)
    );

    integer i;
    initial begin
        $dumpfile("tb_wc.vcd");
        $dumpvars(0, tb_wc);
        for (i = 0; i < 1024; i = i + 1) begin
            core_a.dpram[i] = 32'h00000013;
            core_b.dpram[i] = 32'h00000013;
        end
        $readmemh("wc_a.hex", core_a.dpram);
        $readmemh("wc_b.hex", core_b.dpram);

        repeat (4) @(posedge clk);
        reset = 0;
        repeat (20) @(posedge clk);
        cpu_rst_req = 0;
    end

    initial begin
        wait (core_a.dpram[1023] == 32'd42);
        $display("[%0t] PASS: core_a got wander_call return = 42", $time);
        $display("ALL PASS");
        $finish;
    end

    initial begin
        #1000000;
        $display("TIMEOUT: a[1023]=%h b[1023]=%h", core_a.dpram[1023], core_b.dpram[1023]);
        $finish;
    end
endmodule
