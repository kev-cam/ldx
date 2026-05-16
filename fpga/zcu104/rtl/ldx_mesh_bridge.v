// ldx_mesh_bridge.v — AXI4-Lite slave that owns the mesh from the PS side.
//
// Map (128 KB region, awaddr/araddr 17 bits):
//   0x00000 - 0x18FFF   BRAM windows (25 × 4 KB)
//                       core_idx = (awaddr >> 12); offset_in_core = awaddr[11:0]
//                       core_idx = x*N + y, x,y ∈ [0,N)
//   0x19000             CTRL_RESET  (R/W; bit i = hold core i in reset)
//                                   defaults to all-1 on aresetn
//   0x19100 + ep*0x10   per-boundary-endpoint regs (ep ∈ [0, 4*N))
//     +0x0 PUSH_DATA    (W) enqueue into bridge FIFO[ep] → drives bndry_rx_*
//     +0x4 PUSH_STATUS  (R) bit0 = bridge FIFO[ep] full
//     +0x8 POP_DATA     (R) returns bndry_tx_data[ep], pulses bndry_tx_ready[ep]
//     +0xC POP_STATUS   (R) bit0 = !bndry_tx_valid[ep]
//   0x19F00             MAGIC = 0x4C445834 ("LDX4")

`timescale 1ns/1ps

module ldx_mesh_bridge #(
    parameter integer N = 5
) (
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Lite slave
    input  wire [16:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,

    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [16:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Mesh-side
    output reg  [N*N-1:0] cpu_rst_req_vec,
    output wire [N*N-1:0] load_we_vec,
    output wire [9:0]     load_addr,
    output wire [31:0]    load_data,

    output wire [4*N-1:0]      bndry_rx_valid,
    input  wire [4*N-1:0]      bndry_rx_ready,
    output wire [4*N*32-1:0]   bndry_rx_data,

    input  wire [4*N-1:0]      bndry_tx_valid,
    output wire [4*N-1:0]      bndry_tx_ready,
    input  wire [4*N*32-1:0]   bndry_tx_data
);
    wire clk = aclk;
    wire reset = ~aresetn;
    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // -----------------------------------------------------------------
    // Write FSM (single outstanding txn)
    // -----------------------------------------------------------------
    reg        aw_held, w_held;
    reg [16:0] awaddr_reg;
    reg [31:0] wdata_reg;

    assign s_axi_awready = !aw_held;
    assign s_axi_wready  = !w_held;

    wire aw_fire       = s_axi_awvalid && s_axi_awready;
    wire w_fire        = s_axi_wvalid  && s_axi_wready;
    wire write_fire    = aw_held && w_held && !s_axi_bvalid;

    always @(posedge clk) begin
        if (reset) begin
            aw_held      <= 1'b0;
            w_held       <= 1'b0;
            awaddr_reg   <= 17'd0;
            wdata_reg    <= 32'd0;
            s_axi_bvalid <= 1'b0;
        end else begin
            if (aw_fire) begin
                awaddr_reg <= s_axi_awaddr;
                aw_held    <= 1'b1;
            end
            if (w_fire) begin
                wdata_reg <= s_axi_wdata;
                w_held    <= 1'b1;
            end
            if (write_fire) begin
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                aw_held      <= 1'b0;
                w_held       <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // Write decode: BRAM, CTRL_RESET, boundary push.
    //   awaddr_reg[16:12] = core_idx in [0, N*N) for BRAM; or >= 0x19 for regs
    // -----------------------------------------------------------------
    // Endpoint region: 0x19100 .. 0x19100 + 16*4*N (16 bytes per ep, 4*N eps)
    wire [16:0] aw_ep_off  = awaddr_reg - 17'h19100;
    wire        aw_is_ep   = (awaddr_reg >= 17'h19100)
                            && (aw_ep_off < (4*N) * 17'h10);

    wire is_bram_wr  = write_fire && (awaddr_reg[16:12] < N*N);
    wire is_ctrl_wr  = write_fire && (awaddr_reg == 17'h19000);
    wire is_push_wr  = write_fire && aw_is_ep && (awaddr_reg[3:0] == 4'h0);

    wire [4:0] push_ep = aw_ep_off[8:4];   // 0..19

    assign load_addr = awaddr_reg[11:2];
    assign load_data = wdata_reg;

    // Per-core load_we — strobe the selected core only on write_fire
    genvar gi;
    generate
        for (gi = 0; gi < N*N; gi = gi + 1) begin : g_loadwe
            assign load_we_vec[gi] = is_bram_wr && (awaddr_reg[16:12] == gi);
        end
    endgenerate

    // CTRL_RESET (default = all cores held in reset on aresetn)
    always @(posedge clk) begin
        if (reset) cpu_rst_req_vec <= {(N*N){1'b1}};
        else if (is_ctrl_wr) cpu_rst_req_vec <= wdata_reg[N*N-1:0];
    end

    // -----------------------------------------------------------------
    // 20 bridge FIFOs (push side) — host writes drain into bndry_rx_*
    // -----------------------------------------------------------------
    wire [4*N-1:0] bfifo_push_valid;
    wire [4*N-1:0] bfifo_push_ready;

    generate
        for (gi = 0; gi < 4*N; gi = gi + 1) begin : g_pushfifo
            fifo #(.WIDTH(32), .DEPTH(8)) u_bf (
                .clk(clk), .reset(reset),
                .push_valid(bfifo_push_valid[gi]),
                .push_ready(bfifo_push_ready[gi]),
                .push_data(wdata_reg),
                .pop_valid(bndry_rx_valid[gi]),
                .pop_ready(bndry_rx_ready[gi]),
                .pop_data(bndry_rx_data[gi*32 +: 32]),
                .count()
            );
            assign bfifo_push_valid[gi] = is_push_wr && (push_ep == gi);
        end
    endgenerate

    // -----------------------------------------------------------------
    // Read FSM (3-state)
    //   R_IDLE → latch araddr → R_LOAD → register rdata + pulse pop_ready
    //          → R_RESP → handshake → R_IDLE
    // -----------------------------------------------------------------
    localparam R_IDLE = 2'd0, R_LOAD = 2'd1, R_RESP = 2'd2;
    reg [1:0]  r_state;
    reg [16:0] araddr_reg;

    assign s_axi_arready = (r_state == R_IDLE);
    wire ar_fire = s_axi_arvalid && s_axi_arready;

    // Decode for read
    wire [16:0] ar_ep_total     = araddr_reg - 17'h19100;
    wire        ar_is_magic     = (araddr_reg == 17'h19F00);
    wire        ar_is_ctrl      = (araddr_reg == 17'h19000);
    wire        ar_is_endpoint  = (araddr_reg >= 17'h19100)
                                  && (ar_ep_total < (4*N) * 17'h10);
    wire [4:0]  ar_ep           = ar_ep_total[8:4];
    wire [3:0]  ar_ep_off       = araddr_reg[3:0];
    wire        ar_is_pop_data  = ar_is_endpoint && (ar_ep_off == 4'h8);
    wire        ar_is_pop_stat  = ar_is_endpoint && (ar_ep_off == 4'hC);
    wire        ar_is_push_stat = ar_is_endpoint && (ar_ep_off == 4'h4);

    // Bndry_tx_data is 4*N*32 wide; slice based on ar_ep
    reg [31:0] tx_data_mux;
    integer iep;
    always @(*) begin
        tx_data_mux = 32'd0;
        for (iep = 0; iep < 4*N; iep = iep + 1)
            if (iep == ar_ep) tx_data_mux = bndry_tx_data[iep*32 +: 32];
    end

    // Pulse bndry_tx_ready[ep] in R_LOAD (one cycle) for matching ep when
    // the source side actually has data.
    generate
        for (gi = 0; gi < 4*N; gi = gi + 1) begin : g_txrdy
            assign bndry_tx_ready[gi] = (r_state == R_LOAD)
                                       && ar_is_pop_data
                                       && (ar_ep == gi)
                                       && bndry_tx_valid[gi];
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            r_state      <= R_IDLE;
            araddr_reg   <= 17'd0;
            s_axi_rdata  <= 32'd0;
            s_axi_rvalid <= 1'b0;
        end else case (r_state)
            R_IDLE: begin
                if (ar_fire) begin
                    araddr_reg <= s_axi_araddr;
                    r_state    <= R_LOAD;
                end
            end
            R_LOAD: begin
                // Combinational decode against araddr_reg (just latched)
                if (ar_is_magic)
                    s_axi_rdata <= 32'h4C445834;
                else if (ar_is_ctrl)
                    s_axi_rdata <= {{(32-N*N){1'b0}}, cpu_rst_req_vec};
                else if (ar_is_pop_data)
                    s_axi_rdata <= tx_data_mux;
                else if (ar_is_pop_stat)
                    s_axi_rdata <= {31'd0, ~bndry_tx_valid[ar_ep]};
                else if (ar_is_push_stat)
                    s_axi_rdata <= {31'd0, ~bfifo_push_ready[ar_ep]};
                else
                    s_axi_rdata <= 32'd0;
                s_axi_rvalid <= 1'b1;
                r_state      <= R_RESP;
            end
            R_RESP: begin
                if (s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    r_state      <= R_IDLE;
                end
            end
            default: r_state <= R_IDLE;
        endcase
    end
endmodule
