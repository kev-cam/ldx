// ldx_soc_mesh.v — mesh-node SoC: VexRiscv + CFU + 4 KB BRAM + 4 mesh ports.
//
// Each core has 4 directional ports (N=0, E=1, S=2, W=3). Each port carries:
//   tx_*: outbound stream from this core (FIFO at source)
//   rx_*: inbound stream from neighbor (combinational view of neighbor's FIFO head)
//
// CPU memory map:
//   0x80000000 - 0x80000FFF  BRAM (4 KB)
//   0xF0000000 + 0x10*d  PUSH_DATA[d]   (W: enqueue toward dir d)
//   0xF0000004 + 0x10*d  PUSH_STATUS[d] (R: bit0 = full / !push_ready)
//   0xF0000008 + 0x10*d  POP_DATA[d]    (R: dequeue from dir d, also pops)
//   0xF000000C + 0x10*d  POP_STATUS[d]  (R: bit0 = empty / !rx_valid)
//
// BRAM is loadable externally via `load_*` ports (used by sim TB or
// future AXI-slave wrapper). Held in reset while loading.
//
// Sim-friendly: a HEX_FILE parameter pre-initializes the BRAM via $readmemh.

`timescale 1ns/1ps

module ldx_soc_mesh #(
    parameter [2:0] MY_X = 0,
    parameter [2:0] MY_Y = 0
) (
    input  wire        clk,
    input  wire        reset,

    // BRAM load port (used while CPU held in reset)
    input  wire        load_we,
    input  wire [9:0]  load_addr,
    input  wire [31:0] load_data,
    input  wire        cpu_rst_req,    // 1 = hold CPU in reset

    // Mesh ports — 4 directions; index 0=N, 1=E, 2=S, 3=W
    output wire [3:0]        tx_valid,
    input  wire [3:0]        tx_ready,
    output wire [127:0]      tx_data,   // {dir3, dir2, dir1, dir0}

    input  wire [3:0]        rx_valid,
    output wire [3:0]        rx_ready,
    input  wire [127:0]      rx_data
);
    // -----------------------------------------------------------------
    // Reset logic — 4-cycle settle after release
    // -----------------------------------------------------------------
    reg [3:0] rst_delay;
    always @(posedge clk) begin
        if (reset | cpu_rst_req)
            rst_delay <= 4'hF;
        else if (rst_delay != 0)
            rst_delay <= rst_delay - 1;
    end
    wire cpu_rst = (rst_delay != 0);

    // -----------------------------------------------------------------
    // VexRiscv buses
    // -----------------------------------------------------------------
    wire        ibus_cmd_valid, ibus_cmd_ready;
    wire [31:0] ibus_cmd_payload_pc;
    reg         ibus_rsp_valid_r;
    wire [31:0] ibus_rdata;

    wire        dbus_cmd_valid, dbus_cmd_ready;
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
    // BRAM 4 KB, true dual-port. Port A: ibus (RO). Port B: dbus + load.
    // -----------------------------------------------------------------
    reg [31:0] dpram [0:1023];

    wire        cpu_ram_wr = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_ram && !cpu_rst;
    wire        ram_b_we   = load_we || cpu_ram_wr;
    wire [9:0]  ram_b_addr = load_we ? load_addr
                                     : dbus_cmd_payload_address[11:2];
    wire [31:0] ram_b_wdata = load_we ? load_data : dbus_cmd_payload_data;

    reg [31:0] ram_a_q, ram_a_q_d1, ram_b_q;
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

    always @(posedge clk) begin
        dbus_rsp_valid_r <= dbus_cmd_valid & !dbus_cmd_payload_wr & !cpu_rst;
    end

    // -----------------------------------------------------------------
    // FIFOs per direction (4 total) — outbound only.
    // Push side: CPU MMIO write. Pop side: tx_valid/tx_ready/tx_data.
    // -----------------------------------------------------------------
    wire [3:0]  fifo_push_valid;
    wire [3:0]  fifo_push_ready;
    wire [31:0] fifo_push_data;     // shared bus (only one push per cycle)
    genvar d;
    generate
        for (d = 0; d < 4; d = d + 1) begin : g_fifo
            fifo #(.WIDTH(32), .DEPTH(8)) u_fifo (
                .clk(clk), .reset(cpu_rst),
                .push_valid(fifo_push_valid[d]),
                .push_ready(fifo_push_ready[d]),
                .push_data(fifo_push_data),
                .pop_valid(tx_valid[d]),
                .pop_ready(tx_ready[d]),
                .pop_data(tx_data[32*d +: 32]),
                .count()
            );
        end
    endgenerate

    // -----------------------------------------------------------------
    // CPU MMIO write decode
    //   Address breakdown: [7:4] = port id × 0x10 + offset
    //   We use bits [11:4] = dir/offset; bit [3:0] = byte offset (00 for word)
    // -----------------------------------------------------------------
    //   0x000 .. 0x00F : reserved (older mailbox slot — unused in mesh build)
    //   0x100 .. 0x10F : dir 0 (N)
    //   0x110 .. 0x11F : dir 1 (E)
    //   0x120 .. 0x12F : dir 2 (S)
    //   0x130 .. 0x13F : dir 3 (W)
    //   offset within dir:  +0x00 PUSH_DATA  (W)
    //                       +0x04 PUSH_STATUS (R)
    //                       +0x08 POP_DATA   (R, also dequeues)
    //                       +0x0C POP_STATUS (R)
    wire [11:0] io_addr_now = dbus_cmd_payload_address[11:0];
    wire        io_is_push  = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_io && !cpu_rst
                              && (io_addr_now[11:8] == 4'h1)
                              && (io_addr_now[3:0] == 4'h0);
    wire [1:0]  push_dir    = io_addr_now[5:4];

    assign fifo_push_data = dbus_cmd_payload_data;
    assign fifo_push_valid[0] = io_is_push && (push_dir == 2'd0);
    assign fifo_push_valid[1] = io_is_push && (push_dir == 2'd1);
    assign fifo_push_valid[2] = io_is_push && (push_dir == 2'd2);
    assign fifo_push_valid[3] = io_is_push && (push_dir == 2'd3);

    // -----------------------------------------------------------------
    // CPU MMIO read decode (and POP side-effects)
    // -----------------------------------------------------------------
    wire io_is_pop_data = dbus_cmd_valid && !dbus_cmd_payload_wr && dbus_is_io && !cpu_rst
                          && (io_addr_now[11:8] == 4'h1)
                          && (io_addr_now[3:0] == 4'h8);
    wire [1:0] pop_dir  = io_addr_now[5:4];

    assign rx_ready[0] = io_is_pop_data && (pop_dir == 2'd0) && rx_valid[0];
    assign rx_ready[1] = io_is_pop_data && (pop_dir == 2'd1) && rx_valid[1];
    assign rx_ready[2] = io_is_pop_data && (pop_dir == 2'd2) && rx_valid[2];
    assign rx_ready[3] = io_is_pop_data && (pop_dir == 2'd3) && rx_valid[3];

    // Register the dbus read-response selector for one-cycle latency
    reg [11:0] dbus_io_addr_r;
    reg [31:0] rx_data_sampled_r;
    reg [3:0]  rx_valid_r;
    reg [3:0]  push_ready_r;
    reg        dbus_was_ram_r;

    always @(posedge clk) begin
        dbus_was_ram_r    <= dbus_is_ram;
        dbus_io_addr_r    <= io_addr_now;
        rx_valid_r        <= rx_valid;
        push_ready_r      <= fifo_push_ready;
        case (io_addr_now[5:4])
            2'd0: rx_data_sampled_r <= rx_data[31:0];
            2'd1: rx_data_sampled_r <= rx_data[63:32];
            2'd2: rx_data_sampled_r <= rx_data[95:64];
            2'd3: rx_data_sampled_r <= rx_data[127:96];
        endcase
    end

    always @(*) begin
        if (dbus_was_ram_r) begin
            dbus_rdata = ram_b_q;
        end else if (dbus_io_addr_r == 12'h040) begin
            dbus_rdata = {26'd0, MY_Y, MY_X};   // {MY_Y[2:0], MY_X[2:0]}
        end else begin
            case (dbus_io_addr_r[3:0])
                4'h0: dbus_rdata = 32'd0;   // PUSH_DATA is W-only; read undefined
                4'h4: dbus_rdata = {31'd0, ~push_ready_r[dbus_io_addr_r[5:4]]};  // bit0=full
                4'h8: dbus_rdata = rx_data_sampled_r;
                4'hC: dbus_rdata = {31'd0, ~rx_valid_r[dbus_io_addr_r[5:4]]};    // bit0=empty
                default: dbus_rdata = 32'd0;
            endcase
        end
    end

endmodule
