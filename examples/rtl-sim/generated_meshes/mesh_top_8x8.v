// mesh_top_8x8.v — 8×8 RTL simulation mesh
// Generated automatically by vivado_mesh_gen.py

`timescale 1ns/1ps

module mesh_top_8x8 #(
    parameter integer N = 8
) (
    input  wire        clk,
    input  wire        reset,

    // Per-core reset and BRAM-load
    input  wire [N*N-1:0]      cpu_rst_req_vec,
    input  wire [N*N-1:0]      load_we_vec,
    input  wire [9:0]          load_addr,
    input  wire [31:0]         load_data,

    // Boundary ports — 32 total
    output wire [4*N-1:0]      bndry_tx_valid,
    input  wire [4*N-1:0]      bndry_tx_ready,
    output wire [4*N*32-1:0]   bndry_tx_data,
    input  wire [4*N-1:0]      bndry_rx_valid,
    output wire [4*N-1:0]      bndry_rx_ready,
    input  wire [4*N*32-1:0]   bndry_rx_data,

    // Performance monitoring
    output wire [N*N-1:0]      core_active,
    output wire [31:0]         total_gates_evaluated,
    output wire [31:0]         cross_partition_signals
);

    // Per-core port buses
    wire [3:0]   tx_valid [0:N-1][0:N-1];
    wire [3:0]   tx_ready [0:N-1][0:N-1];
    wire [127:0] tx_data  [0:N-1][0:N-1];
    wire [3:0]   rx_valid [0:N-1][0:N-1];
    wire [3:0]   rx_ready [0:N-1][0:N-1];
    wire [127:0] rx_data  [0:N-1][0:N-1];

    // Core instantiation
    genvar gx, gy;
    generate
        for (gx = 0; gx < N; gx = gx + 1) begin : gx_loop
            for (gy = 0; gy < N; gy = gy + 1) begin : gy_loop
                ldx_soc_mesh #(
                    .MY_X(gx+1),
                    .MY_Y(gy+1),
                    .HEX_FILE($sformatf("firmware_core_%0d_%0d.hex", gx, gy))
                ) core (
                    .clk(clk),
                    .reset(reset),
                    .load_we(load_we_vec[gx*N + gy]),
                    .load_addr(load_addr),
                    .load_data(load_data),
                    .cpu_rst_req(cpu_rst_req_vec[gx*N + gy]),
                    .tx_valid(tx_valid[gx][gy]),
                    .tx_ready(tx_ready[gx][gy]),
                    .tx_data (tx_data [gx][gy]),
                    .rx_valid(rx_valid[gx][gy]),
                    .rx_ready(rx_ready[gx][gy]),
                    .rx_data (rx_data [gx][gy])
                );

                // Performance monitoring
                assign core_active[gx*N + gy] = |tx_valid[gx][gy] | |rx_valid[gx][gy];
            end
        end
    endgenerate

    // Mesh interconnect (same pattern as original mesh_top.v)
    generate
        for (gx = 0; gx < N; gx = gx + 1) begin : x_wire
            for (gy = 0; gy < N; gy = gy + 1) begin : y_wire

                // East-West connections
                if (gx < N-1) begin : east_link
                    assign rx_valid[gx+1][gy][3]      = tx_valid[gx][gy][1];
                    assign rx_data [gx+1][gy][127:96] = tx_data [gx][gy][63:32];
                    assign tx_ready[gx][gy][1]        = rx_ready[gx+1][gy][3];

                    assign rx_valid[gx][gy][1]        = tx_valid[gx+1][gy][3];
                    assign rx_data [gx][gy][63:32]    = tx_data [gx+1][gy][127:96];
                    assign tx_ready[gx+1][gy][3]      = rx_ready[gx][gy][1];
                end else begin : east_bndry
                    assign bndry_tx_valid[N + gy]                = tx_valid[gx][gy][1];
                    assign bndry_tx_data [(N+gy)*32 +: 32]       = tx_data [gx][gy][63:32];
                    assign tx_ready[gx][gy][1]                   = bndry_tx_ready[N + gy];

                    assign rx_valid[gx][gy][1]                   = bndry_rx_valid[N + gy];
                    assign rx_data [gx][gy][63:32]               = bndry_rx_data[(N+gy)*32 +: 32];
                    assign bndry_rx_ready[N + gy]                = rx_ready[gx][gy][1];
                end

                if (gx == 0) begin : west_bndry
                    assign bndry_tx_valid[3*N + gy]              = tx_valid[gx][gy][3];
                    assign bndry_tx_data [(3*N+gy)*32 +: 32]     = tx_data [gx][gy][127:96];
                    assign tx_ready[gx][gy][3]                   = bndry_tx_ready[3*N + gy];

                    assign rx_valid[gx][gy][3]                   = bndry_rx_valid[3*N + gy];
                    assign rx_data [gx][gy][127:96]              = bndry_rx_data[(3*N+gy)*32 +: 32];
                    assign bndry_rx_ready[3*N + gy]              = rx_ready[gx][gy][3];
                end

                // North-South connections
                if (gy < N-1) begin : north_link
                    assign rx_valid[gx][gy+1][2]      = tx_valid[gx][gy][0];
                    assign rx_data [gx][gy+1][95:64]  = tx_data [gx][gy][31:0];
                    assign tx_ready[gx][gy][0]        = rx_ready[gx][gy+1][2];

                    assign rx_valid[gx][gy][0]        = tx_valid[gx][gy+1][2];
                    assign rx_data [gx][gy][31:0]     = tx_data [gx][gy+1][95:64];
                    assign tx_ready[gx][gy+1][2]      = rx_ready[gx][gy][0];
                end else begin : north_bndry
                    assign bndry_tx_valid[0*N + gx]              = tx_valid[gx][gy][0];
                    assign bndry_tx_data [(0*N+gx)*32 +: 32]     = tx_data [gx][gy][31:0];
                    assign tx_ready[gx][gy][0]                   = bndry_tx_ready[0*N + gx];

                    assign rx_valid[gx][gy][0]                   = bndry_rx_valid[0*N + gx];
                    assign rx_data [gx][gy][31:0]                = bndry_rx_data[(0*N+gx)*32 +: 32];
                    assign bndry_rx_ready[0*N + gx]              = rx_ready[gx][gy][0];
                end

                if (gy == 0) begin : south_bndry
                    assign bndry_tx_valid[2*N + gx]              = tx_valid[gx][gy][2];
                    assign bndry_tx_data [(2*N+gx)*32 +: 32]     = tx_data [gx][gy][95:64];
                    assign tx_ready[gx][gy][2]                   = bndry_tx_ready[2*N + gx];

                    assign rx_valid[gx][gy][2]                   = bndry_rx_valid[2*N + gx];
                    assign rx_data [gx][gy][95:64]               = bndry_rx_data[(2*N+gx)*32 +: 32];
                    assign bndry_rx_ready[2*N + gx]              = rx_ready[gx][gy][2];
                end
            end
        end
    endgenerate

    // Performance counters
    reg [31:0] gate_counter;
    reg [31:0] signal_counter;

    always @(posedge clk) begin
        if (reset) begin
            gate_counter <= 0;
            signal_counter <= 0;
        end else begin
            gate_counter <= gate_counter + $countones(core_active);
            signal_counter <= signal_counter + $countones(bndry_tx_valid);
        end
    end

    assign total_gates_evaluated = gate_counter;
    assign cross_partition_signals = signal_counter;

endmodule