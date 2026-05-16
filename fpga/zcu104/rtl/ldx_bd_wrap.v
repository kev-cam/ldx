// ldx_bd_wrap.v — top-level wrapper for Vivado BD: bridge + mesh in one module.
// Single AXI4-Lite slave; everything else stays internal.

`timescale 1ns/1ps

module ldx_bd_wrap #(
    parameter integer N = 5
) (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [16:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [16:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
);

    wire [N*N-1:0]    cpu_rst_req_vec;
    wire [N*N-1:0]    load_we_vec;
    wire [9:0]        load_addr;
    wire [31:0]       load_data;

    wire [4*N-1:0]    bndry_rx_valid;
    wire [4*N-1:0]    bndry_rx_ready;
    wire [4*N*32-1:0] bndry_rx_data;
    wire [4*N-1:0]    bndry_tx_valid;
    wire [4*N-1:0]    bndry_tx_ready;
    wire [4*N*32-1:0] bndry_tx_data;

    ldx_mesh_bridge #(.N(N)) bridge (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr (s_axi_awaddr ), .s_axi_awprot (s_axi_awprot ),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata  (s_axi_wdata  ), .s_axi_wstrb  (s_axi_wstrb  ),
        .s_axi_wvalid (s_axi_wvalid ), .s_axi_wready (s_axi_wready ),
        .s_axi_bresp  (s_axi_bresp  ), .s_axi_bvalid (s_axi_bvalid ),
        .s_axi_bready (s_axi_bready ),
        .s_axi_araddr (s_axi_araddr ), .s_axi_arprot (s_axi_arprot ),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata  (s_axi_rdata  ), .s_axi_rresp  (s_axi_rresp  ),
        .s_axi_rvalid (s_axi_rvalid ), .s_axi_rready (s_axi_rready ),
        .cpu_rst_req_vec(cpu_rst_req_vec),
        .load_we_vec(load_we_vec), .load_addr(load_addr), .load_data(load_data),
        .bndry_rx_valid(bndry_rx_valid), .bndry_rx_ready(bndry_rx_ready),
        .bndry_rx_data (bndry_rx_data ),
        .bndry_tx_valid(bndry_tx_valid), .bndry_tx_ready(bndry_tx_ready),
        .bndry_tx_data (bndry_tx_data )
    );

    mesh_top #(.N(N)) mesh (
        .clk(aclk), .reset(~aresetn),
        .cpu_rst_req_vec(cpu_rst_req_vec),
        .load_we_vec(load_we_vec), .load_addr(load_addr), .load_data(load_data),
        .bndry_tx_valid(bndry_tx_valid), .bndry_tx_ready(bndry_tx_ready),
        .bndry_tx_data (bndry_tx_data ),
        .bndry_rx_valid(bndry_rx_valid), .bndry_rx_ready(bndry_rx_ready),
        .bndry_rx_data (bndry_rx_data )
    );

endmodule
