// ldx_top.v — DE2i-150 top-level: PCIe QSYS system.
//
// Phase 1: PCIe link test with on-chip RAM scratchpad.
// Phase 2: Replace on-chip RAM with pcie_bar_bridge + accel_slot.

module ldx_top (
    input  wire        pcie_refclk,   // 100 MHz from PCIe connector
    input  wire        pcie_rx,       // PCIe serial receive
    output wire        pcie_tx,       // PCIe serial transmit
    input  wire        pcie_perstn,   // PCIe reset (active low)
    input  wire        clk_50,        // 50 MHz board oscillator
    // input  wire [3:0]  key,        // Push-buttons (active low) -- reserved for future use
    output wire [3:0]  led            // Green LEDs
);

    wire pcie_core_clk;
    wire pcie_core_rstn;

    // ---- PCIe QSYS System ----
    pcie_system u_pcie_system (
        .cal_blk_clk_clk         (clk_50),
        .reconfig_gxbclk_clk     (clk_50),
        .core_clk_clk            (pcie_core_clk),
        .core_reset_reset_n      (pcie_core_rstn),
        .refclk_export           (pcie_refclk),
        .pcie_rstn_export        (pcie_perstn),
        .rx_in_rx_datain_0       (pcie_rx),
        .tx_out_tx_dataout_0     (pcie_tx),
        .reconfig_togxb_data     (4'd0),
        .reconfig_fromgxb_0_data (),
        .test_in_test_in         (40'd0)
    );

    // ---- Status LEDs ----
    reg [25:0] led_cnt;
    always @(posedge pcie_core_clk or negedge pcie_core_rstn) begin
        if (!pcie_core_rstn)
            led_cnt <= 0;
        else
            led_cnt <= led_cnt + 1;
    end

    assign led[0] = led_cnt[25];    // blink = PCIe core alive
    assign led[1] = pcie_core_rstn; // steady = reset deasserted
    assign led[2] = 1'b0;
    assign led[3] = 1'b0;

endmodule
