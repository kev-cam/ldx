// ldx_soc_axi.v — VexRiscv + CFU + BRAM + mailbox, AXI4-Lite slave.
//
// Single-core ZCU104 milestone-1 SoC:
//   * one VexRiscv RV32I (with CFU)
//   * 4 KB true-dual-port BRAM shared between PS (via AXI4-Lite) and CPU
//   * mailbox register pair for host-relayed hypercalls (putc etc.)
//
// CPU memory map:
//   0x80000000 - 0x80000FFF  ITCM/DTCM BRAM (4 KB, code + data + stack)
//   0xF0000000               MBOX_DATA  (W = post hypercall, R = PS-returned result)
//   0xF0000004               MBOX_STATUS  bit0 = pending
//
// AXI4-Lite slave map (PS side, 8 KB region):
//   0x0000 - 0x0FFF  BRAM window (byte-addressed, word-access only,
//                                 BRAM access only valid while CPU held in reset)
//   0x1F00           CTRL  bit0 = cpu_reset (1 = hold, 0 = run)
//   0x1F04           MBOX_DATA  (R = last CPU post, W = reply / clears pending)
//   0x1F08           MBOX_STATUS  bit0 = pending
//   0x1F80           MAGIC = 32'h4C445833  ("LDX3")

`timescale 1ns/1ps

module ldx_soc_axi (
    input  wire        aclk,
    input  wire        aresetn,

    // ---- AXI4-Lite slave ----
    input  wire [12:0] s_axi_awaddr,
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

    input  wire [12:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output wire        hypercall_pending
);

    wire clk = aclk;
    wire reset = ~aresetn;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    // Forward declaration of BRAM port-B read data (used by AXI R mux below)
    reg [31:0] ram_b_q;
    reg [31:0] ram_a_q, ram_a_q_d1;

    // -----------------------------------------------------------------
    // Control / mailbox registers
    // -----------------------------------------------------------------
    reg         cpu_reset_reg;
    reg         mbox_pending;
    reg [31:0]  mbox_to_ps;
    reg [31:0]  mbox_to_cpu;
    assign hypercall_pending = mbox_pending;

    reg [3:0] rst_delay;
    always @(posedge clk) begin
        if (reset | cpu_reset_reg)
            rst_delay <= 4'hF;
        else if (rst_delay != 0)
            rst_delay <= rst_delay - 1;
    end
    wire cpu_rst = (rst_delay != 0);

    // -----------------------------------------------------------------
    // VexRiscv buses
    // -----------------------------------------------------------------
    wire        ibus_cmd_valid;
    wire        ibus_cmd_ready;
    wire [31:0] ibus_cmd_payload_pc;
    reg         ibus_rsp_valid_r;
    wire [31:0] ibus_rdata;

    wire        dbus_cmd_valid;
    wire        dbus_cmd_ready;
    wire        dbus_cmd_payload_wr;
    wire [3:0]  dbus_cmd_payload_mask;
    wire [31:0] dbus_cmd_payload_address;
    wire [31:0] dbus_cmd_payload_data;
    wire [1:0]  dbus_cmd_payload_size;
    reg         dbus_rsp_valid_r;
    reg  [31:0] dbus_rdata;

    wire        cfu_cmd_valid, cfu_cmd_ready;
    wire [2:0]  cfu_cmd_function_id;
    wire [31:0] cfu_cmd_inputs_0, cfu_cmd_inputs_1;
    wire        cfu_rsp_valid, cfu_rsp_ready;
    wire [31:0] cfu_rsp_outputs_0;

    VexRiscv cpu (
        .clk(clk), .reset(cpu_rst),
        .timerInterrupt(1'b0), .externalInterrupt(1'b0), .softwareInterrupt(1'b0),
        .iBus_cmd_valid(ibus_cmd_valid), .iBus_cmd_ready(ibus_cmd_ready),
        .iBus_cmd_payload_pc(ibus_cmd_payload_pc),
        .iBus_rsp_valid(ibus_rsp_valid_r), .iBus_rsp_payload_error(1'b0),
        .iBus_rsp_payload_inst(ibus_rdata),
        .dBus_cmd_valid(dbus_cmd_valid), .dBus_cmd_ready(dbus_cmd_ready),
        .dBus_cmd_payload_wr(dbus_cmd_payload_wr),
        .dBus_cmd_payload_mask(dbus_cmd_payload_mask),
        .dBus_cmd_payload_address(dbus_cmd_payload_address),
        .dBus_cmd_payload_data(dbus_cmd_payload_data),
        .dBus_cmd_payload_size(dbus_cmd_payload_size),
        .dBus_rsp_ready(dbus_rsp_valid_r), .dBus_rsp_error(1'b0),
        .dBus_rsp_data(dbus_rdata),
        .CfuPlugin_bus_cmd_valid(cfu_cmd_valid),
        .CfuPlugin_bus_cmd_ready(cfu_cmd_ready),
        .CfuPlugin_bus_cmd_payload_function_id(cfu_cmd_function_id),
        .CfuPlugin_bus_cmd_payload_inputs_0(cfu_cmd_inputs_0),
        .CfuPlugin_bus_cmd_payload_inputs_1(cfu_cmd_inputs_1),
        .CfuPlugin_bus_rsp_valid(cfu_rsp_valid),
        .CfuPlugin_bus_rsp_ready(cfu_rsp_ready),
        .CfuPlugin_bus_rsp_payload_outputs_0(cfu_rsp_outputs_0)
    );

    ldx_cfu cfu (
        .clk(clk), .reset(cpu_rst),
        .cmd_valid(cfu_cmd_valid), .cmd_ready(cfu_cmd_ready),
        .cmd_function_id(cfu_cmd_function_id),
        .cmd_inputs_0(cfu_cmd_inputs_0), .cmd_inputs_1(cfu_cmd_inputs_1),
        .rsp_valid(cfu_rsp_valid), .rsp_ready(cfu_rsp_ready),
        .rsp_outputs_0(cfu_rsp_outputs_0)
    );

    wire dbus_is_ram = (dbus_cmd_payload_address[31:28] == 4'h8);
    wire dbus_is_io  = (dbus_cmd_payload_address[31:28] == 4'hF);
    assign ibus_cmd_ready = 1'b1;
    assign dbus_cmd_ready = 1'b1;

    // -----------------------------------------------------------------
    // AXI4-Lite write channel
    //   Single outstanding txn. Accept AW and W independently, then issue B.
    // -----------------------------------------------------------------
    reg        aw_held, w_held;
    reg [12:0] awaddr_reg;
    reg [31:0] wdata_reg;
    reg [3:0]  wstrb_reg;

    assign s_axi_awready = !aw_held;
    assign s_axi_wready  = !w_held;

    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire  = s_axi_wvalid  && s_axi_wready;

    wire ps_write_fire = aw_held && w_held && !s_axi_bvalid;

    always @(posedge clk) begin
        if (reset) begin
            aw_held    <= 1'b0;
            w_held     <= 1'b0;
            awaddr_reg <= 13'd0;
            wdata_reg  <= 32'd0;
            wstrb_reg  <= 4'd0;
            s_axi_bvalid <= 1'b0;
        end else begin
            if (aw_fire) begin
                awaddr_reg <= s_axi_awaddr;
                aw_held    <= 1'b1;
            end
            if (w_fire) begin
                wdata_reg <= s_axi_wdata;
                wstrb_reg <= s_axi_wstrb;
                w_held    <= 1'b1;
            end
            if (ps_write_fire) begin
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                aw_held      <= 1'b0;
                w_held       <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // AXI4-Lite read channel
    //   States: IDLE → drive AR ready, accept addr, start BRAM read
    //           WAIT → BRAM lookup in flight (1 cycle)
    //           RESP → drive R until handshake, then IDLE
    // -----------------------------------------------------------------
    localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_RESP = 2'd2;
    reg [1:0]  r_state;
    reg [12:0] araddr_reg;

    assign s_axi_arready = (r_state == R_IDLE);
    wire ar_fire = s_axi_arvalid && s_axi_arready;

    always @(posedge clk) begin
        if (reset) begin
            r_state    <= R_IDLE;
            araddr_reg <= 13'd0;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else case (r_state)
            R_IDLE: begin
                if (ar_fire) begin
                    araddr_reg <= s_axi_araddr;
                    r_state    <= R_WAIT;
                end
            end
            R_WAIT: begin
                // BRAM clocked the lookup using araddr_reg this cycle;
                // ram_b_q will be valid in the next state's first read.
                r_state <= R_RESP;
            end
            R_RESP: begin
                if (!s_axi_rvalid) begin
                    s_axi_rvalid <= 1'b1;
                    if (araddr_reg < 13'h1000)
                        s_axi_rdata <= ram_b_q;
                    else case (araddr_reg)
                        13'h1F00: s_axi_rdata <= {31'd0, cpu_reset_reg};
                        13'h1F04: s_axi_rdata <= mbox_to_ps;
                        13'h1F08: s_axi_rdata <= {31'd0, mbox_pending};
                        13'h1F80: s_axi_rdata <= 32'h4C445833;
                        default:  s_axi_rdata <= 32'd0;
                    endcase
                end else if (s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    r_state      <= R_IDLE;
                end
            end
            default: r_state <= R_IDLE;
        endcase
    end

    // -----------------------------------------------------------------
    // BRAM 4 KB, true dual-port (Vivado-inferable)
    //   Port A: ibus (read-only, 2-cycle latency via reg pipe)
    //   Port B: dbus + AXI (read/write, 1-cycle latency)
    // -----------------------------------------------------------------
    reg [31:0] dpram [0:1023];

    wire        ps_ram_wr   = ps_write_fire && (awaddr_reg < 13'h1000) && cpu_reset_reg;
    wire        cpu_ram_wr  = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_ram && !cpu_rst;
    wire        ram_b_we    = ps_ram_wr || cpu_ram_wr;
    wire [9:0]  ram_b_waddr = cpu_reset_reg ? awaddr_reg[11:2]
                                            : dbus_cmd_payload_address[11:2];
    wire [31:0] ram_b_wdata = cpu_reset_reg ? wdata_reg : dbus_cmd_payload_data;
    wire [9:0]  ram_b_raddr = cpu_rst ? araddr_reg[11:2]
                                      : dbus_cmd_payload_address[11:2];
    wire [9:0]  ram_b_addr  = ram_b_we ? ram_b_waddr : ram_b_raddr;

    always @(posedge clk) begin
        ram_a_q    <= dpram[ibus_cmd_payload_pc[11:2]];
        ram_a_q_d1 <= ram_a_q;
    end

    always @(posedge clk) begin
        if (ram_b_we) dpram[ram_b_addr] <= ram_b_wdata;
        ram_b_q <= dpram[ram_b_addr];
    end

    assign ibus_rdata = ram_a_q_d1;
    reg ibus_rsp_valid_d1;
    always @(posedge clk) begin
        ibus_rsp_valid_d1 <= ibus_cmd_valid & !cpu_rst;
        ibus_rsp_valid_r  <= ibus_rsp_valid_d1;
    end

    // -----------------------------------------------------------------
    // CPU data bus reads
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        dbus_rsp_valid_r <= dbus_cmd_valid & !dbus_cmd_payload_wr & !cpu_rst;
    end

    reg dbus_was_ram_r;
    reg [7:0] dbus_io_addr_r;
    always @(posedge clk) begin
        dbus_was_ram_r <= dbus_is_ram;
        dbus_io_addr_r <= dbus_cmd_payload_address[7:0];
    end

    always @(*) begin
        if (dbus_was_ram_r) begin
            dbus_rdata = ram_b_q;
        end else case (dbus_io_addr_r)
            8'h00:   dbus_rdata = mbox_to_cpu;
            8'h04:   dbus_rdata = {31'd0, mbox_pending};
            default: dbus_rdata = 32'd0;
        endcase
    end

    // -----------------------------------------------------------------
    // CPU data writes to MMIO + PS register writes
    // -----------------------------------------------------------------
    wire cpu_mbox_data_wr = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_io
                            && (dbus_cmd_payload_address[7:0] == 8'h00) && !cpu_rst;
    wire ps_ctrl_wr       = ps_write_fire && (awaddr_reg == 13'h1F00);
    wire ps_mbox_data_wr  = ps_write_fire && (awaddr_reg == 13'h1F04);

    always @(posedge clk) begin
        if (reset) begin
            cpu_reset_reg <= 1'b1;
            mbox_pending  <= 1'b0;
            mbox_to_ps    <= 32'd0;
            mbox_to_cpu   <= 32'd0;
        end else begin
            if (cpu_mbox_data_wr) begin
                mbox_to_ps   <= dbus_cmd_payload_data;
                mbox_pending <= 1'b1;
            end
            if (ps_mbox_data_wr) begin
                mbox_to_cpu  <= wdata_reg;
                mbox_pending <= 1'b0;
            end
            if (ps_ctrl_wr) begin
                cpu_reset_reg <= wdata_reg[0];
            end
        end
    end

endmodule
