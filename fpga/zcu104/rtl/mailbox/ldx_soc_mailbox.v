// ldx_soc_mailbox.v — mesh node SoC with the mailbox fabric in place of the
// 4-direction mesh FIFOs. VexRiscv + ldx_cfu + gate-compute hook + 4 KB BRAM
// are unchanged (lifted from ldx_soc_mesh.v); the network side is now ONE
// AXI-Stream port into mb_router, driven by mb_nif + mb_slot_file over MMIO.
//
// MMIO (0xF... IO window) — replaces the old PUSH/POP/STATUS block:
//   0xF..000 SEND_W0      (W)  latch outgoing word0
//   0xF..004 SEND_D1      (W)  latch payload + fire direct send
//   0xF..008 READY_MASK   (R)  incoming-slot ready bitmap
//   0xF..00C FREE_MASK    (R)  free bitmap
//   0xF..010 SLOT_LIMIT   (RW)
//   0xF..014 MAILBOX_BASE (RW) base the CPU reads incoming slots from (see below)
//   0xF..018 REGION_BASE  (RW) active/inactive signal region base (used later)
//   0xF..01C DONE_SLOT    (W)  free a drained slot (clears ready, sets free)
//   0xF..040 MY_YX        (R)  {MY_Y, MY_X}
//   0xF..800..FFF SLOT window (R) — read incoming slot words:
//                 addr = base + slot*16 + woff*4  -> mb_slot_file.rd
//
// externalInterrupt = (ready_mask != 0) | cycle_advance.  M1 is a single node
// (TB loops egress->ingress); the barrier/4x4 wiring is M2.

`timescale 1ns/1ps
`include "mailbox_pkg.sv"

module ldx_soc_mailbox
  import mailbox_pkg::*;
#(
    parameter [3:0] MY_X = 0,
    parameter [3:0] MY_Y = 0
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        load_we,
    input  wire [9:0]  load_addr,
    input  wire [31:0] load_data,
    input  wire        cpu_rst_req,

    // single network port to mb_router
    output wire                 m_valid,
    input  wire                 m_ready,
    output wire [WORD_W-1:0]    m_data,
    output wire                 m_last,
    output wire                 m_off_array,
    input  wire                 s_valid,
    output wire                 s_ready,
    input  wire [WORD_W-1:0]    s_data,
    input  wire                 s_last,

    // barrier hooks (used at M2; tie off for single-node M1)
    input  wire                 cycle_parity,
    input  wire                 cycle_advance,
    output wire                 core_busy,
    output wire                 nif_busy,
    output wire                 pkt_sent,
    output wire                 pkt_deliv
);
    // ----- reset (4-cycle settle) -------------------------------------------
    reg [3:0] rst_delay;
    always @(posedge clk) begin
        if (reset | cpu_rst_req) rst_delay <= 4'hF;
        else if (rst_delay != 0) rst_delay <= rst_delay - 1;
    end
    wire cpu_rst = (rst_delay != 0);

    // ----- VexRiscv buses ---------------------------------------------------
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

    wire        mb_irq = (mb_ready_mask != 0) | cycle_advance;

    VexRiscv cpu (
        .clk(clk), .reset(cpu_rst),
        .timerInterrupt(1'b0), .externalInterrupt(mb_irq), .softwareInterrupt(1'b0),
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
    assign dbus_cmd_ready  = 1'b1;          // (gate stall omitted in M1 build)

    // ----- 4 KB program/data BRAM (ibus RO port A, dbus port B) -------------
    reg [31:0] dpram [0:1023] /* verilator public_flat_rd */;
    wire        cpu_ram_wr = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_ram && !cpu_rst;
    wire        ram_b_we   = load_we || cpu_ram_wr;
    wire [9:0]  ram_b_addr = load_we ? load_addr : dbus_cmd_payload_address[11:2];
    wire [31:0] ram_b_wdata= load_we ? load_data : dbus_cmd_payload_data;

    reg [31:0] ram_a_q, ram_a_q_d1, ram_b_q;
    always @(posedge clk) begin
        ram_a_q    <= dpram[ibus_cmd_payload_pc[11:2]];
        ram_a_q_d1 <= ram_a_q;
        if (ram_b_we) dpram[ram_b_addr] <= ram_b_wdata;
        ram_b_q    <= dpram[ram_b_addr];
    end
    assign ibus_rdata = ram_a_q_d1;         // (gate-vtable hook omitted in M1 build)

    reg ibus_rsp_valid_d1;
    always @(posedge clk) begin
        ibus_rsp_valid_d1 <= ibus_cmd_valid & !cpu_rst;
        ibus_rsp_valid_r  <= ibus_rsp_valid_d1;
    end
    always @(posedge clk)
        dbus_rsp_valid_r <= dbus_cmd_valid & !dbus_cmd_payload_wr & !cpu_rst;

    // =====================================================================
    // Mailbox: slot file + NIF + MMIO
    // =====================================================================
    wire [11:0] io_addr = dbus_cmd_payload_address[11:0];
    wire        io_wr   = dbus_cmd_valid && dbus_cmd_payload_wr  && dbus_is_io && !cpu_rst;
    wire        io_rd   = dbus_cmd_valid && !dbus_cmd_payload_wr && dbus_is_io && !cpu_rst;

    reg  [WORD_W-1:0] send_w0_r, send_d1_r;
    reg  [SLOT_ID_W:0]    slot_limit_r;
    reg  [BRAM_OFS_W-1:0] region_base_r;
    reg  [31:0]           mailbox_base_r;
    reg                   busy_reg;        // worker declares "busy this cycle"
    reg  [31:0]           cycle_cnt_r;     // ++ on each barrier advance (worker polls)

    // direct-send adapter: SEND_D1 write fires; hold ds_valid until ds_ack
    reg  ds_pending;
    wire ds_ack;
    wire ds_valid = ds_pending && !ds_ack;

    // slot-file <-> NIF
    wire                  sf_alloc_req, sf_alloc_gnt;
    wire [SLOT_ID_W-1:0]  sf_alloc_slot;
    wire                  sf_wr_en, sf_commit_en;
    wire [SLOT_ID_W-1:0]  sf_wr_slot, sf_commit_slot;
    wire [$clog2(SLOT_WORDS)-1:0] sf_wr_woff;
    wire [WORD_W-1:0]     sf_wr_data;
    wire [N_SLOTS_MAX-1:0] mb_free_mask /*verilator public_flat_rd*/, mb_ready_mask /*verilator public_flat_rd*/;

    // CPU reads incoming slot words through the slot window
    wire                  cpu_slot_rd = io_rd && io_addr[11];     // >= 0x800
    wire [SLOT_ID_W-1:0]  cpu_rd_slot = io_addr[4 +: SLOT_ID_W];
    wire [$clog2(SLOT_WORDS)-1:0] cpu_rd_woff = io_addr[3:2];
    wire [WORD_W-1:0]     sf_rd_data;

    // DONE_SLOT write frees a drained slot
    wire                  done_en   = io_wr && (io_addr[11:0] == 12'h01C);
    wire [SLOT_ID_W-1:0]  done_slot = dbus_cmd_payload_data[SLOT_ID_W-1:0];

    mb_slot_file u_sf (
        .clk(clk), .rst(cpu_rst), .slot_limit(slot_limit_r),
        .alloc_req(sf_alloc_req), .alloc_gnt(sf_alloc_gnt), .alloc_slot(sf_alloc_slot),
        .wr_en(sf_wr_en), .wr_slot(sf_wr_slot), .wr_woff(sf_wr_woff), .wr_data(sf_wr_data),
        .commit_en(sf_commit_en), .commit_slot(sf_commit_slot),
        .done_en(done_en), .done_slot(done_slot),
        .ack_en(1'b0), .ack_slot('0),
        .rd_slot(cpu_rd_slot), .rd_woff(cpu_rd_woff), .rd_data(sf_rd_data),
        .free_mask(mb_free_mask), .ready_mask(mb_ready_mask)
    );

    mb_nif u_nif (
        .clk(clk), .rst(cpu_rst),
        .my_y({4'd0, MY_Y}), .my_x({4'd0, MY_X}), .slot_limit(slot_limit_r),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data), .s_last(s_last),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data), .m_last(m_last),
        .m_off_array(m_off_array),
        .send_req(1'b0), .send_slot('0), .send_busy(),
        .ds_valid(ds_valid), .ds_w0(send_w0_r), .ds_d1(send_d1_r), .ds_ack(ds_ack),
        .sf_alloc_req(sf_alloc_req), .sf_alloc_gnt(sf_alloc_gnt), .sf_alloc_slot(sf_alloc_slot),
        .sf_wr_en(sf_wr_en), .sf_wr_slot(sf_wr_slot), .sf_wr_woff(sf_wr_woff), .sf_wr_data(sf_wr_data),
        .sf_commit_en(sf_commit_en), .sf_commit_slot(sf_commit_slot),
        .sf_ack_en(), .sf_ack_slot(),
        .sf_rd_slot(), .sf_rd_woff(), .sf_rd_data('0),
        .free_mask(mb_free_mask), .ready_mask(mb_ready_mask), .nif_busy(nif_busy),
        .pkt_sent(pkt_sent), .pkt_deliv(pkt_deliv)
    );

    // ----- MMIO writes ------------------------------------------------------
    always @(posedge clk) begin
        if (cpu_rst) begin
            ds_pending     <= 1'b0;
            slot_limit_r   <= N_SLOTS_MAX[SLOT_ID_W:0];
            region_base_r  <= '0;
            mailbox_base_r <= 32'hF000_0800;
            busy_reg       <= 1'b0;
            cycle_cnt_r    <= 32'd0;
        end else begin
            if (cycle_advance) cycle_cnt_r <= cycle_cnt_r + 1;
            if (ds_pending && ds_ack) ds_pending <= 1'b0;
            if (io_wr) begin
                case (io_addr[11:0])
                    12'h000: send_w0_r      <= dbus_cmd_payload_data;
                    12'h004: begin send_d1_r <= dbus_cmd_payload_data; ds_pending <= 1'b1; end
                    12'h010: slot_limit_r   <= dbus_cmd_payload_data[SLOT_ID_W:0];
                    12'h014: mailbox_base_r <= dbus_cmd_payload_data;
                    12'h018: region_base_r  <= dbus_cmd_payload_data[BRAM_OFS_W-1:0];
                    12'h020: busy_reg       <= dbus_cmd_payload_data[0];
                    default: ;
                endcase
            end
        end
    end

    // ----- MMIO / RAM read response (1-cycle latency) -----------------------
    reg        dbus_was_ram_r, cpu_slot_rd_r;
    reg [11:0] io_addr_r;
    reg [31:0] sf_rd_data_r;              // align async slot read with the 1-cyc dbus rsp
    always @(posedge clk) begin
        dbus_was_ram_r <= dbus_is_ram;
        cpu_slot_rd_r  <= cpu_slot_rd;
        io_addr_r      <= io_addr;
        sf_rd_data_r   <= sf_rd_data;
    end
    always @(*) begin
        if (dbus_was_ram_r)      dbus_rdata = ram_b_q;
        else if (cpu_slot_rd_r)  dbus_rdata = sf_rd_data_r;
        else case (io_addr_r[11:0])
            12'h008: dbus_rdata = mb_ready_mask;
            12'h00C: dbus_rdata = mb_free_mask;
            12'h010: dbus_rdata = {{(32-(SLOT_ID_W+1)){1'b0}}, slot_limit_r};
            12'h014: dbus_rdata = mailbox_base_r;
            12'h018: dbus_rdata = {{(32-BRAM_OFS_W){1'b0}}, region_base_r};
            12'h020: dbus_rdata = {31'd0, busy_reg};
            12'h024: dbus_rdata = cycle_cnt_r;
            12'h040: dbus_rdata = {24'd0, MY_Y, MY_X};
            default: dbus_rdata = 32'd0;
        endcase
    end

    // node is busy if the worker says so OR it has unprocessed incoming
    assign core_busy = busy_reg | (mb_ready_mask != 0);

endmodule
