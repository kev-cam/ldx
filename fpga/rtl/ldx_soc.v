// ldx_soc.v — VexRiscv SoC with CFU, as QSYS Avalon-MM slave.
//
// Self-contained: VexRiscv + ldx_cfu + dual-port RAM + control registers.
// Same Avalon-MM slave interface as ldx_accel_slave — drop-in replacement.
//
// Memory map (VexRiscv side):
//   0x80000000 - 0x80007FFF: On-chip RAM (32 KB)
//   0xF0000000: Result0  0xF0000004: Done  0xF0000008-10: Result1-3
//
// PCIe BAR0 layout (8 KB, word-addressed via avs_address[9:0]):
//   0x000-0x7FF: RAM (first 8KB, word-addressed)
//   0x7C0:       Control (bit 0 = cpu_reset, 1=hold 0=run)
//   0x7C1:       Status (bit 0 = done)
//   0x7C2-0x7C5: Result[0..3]
//   0x7E0:       Magic "LDX2" (0x4C445832)

module ldx_soc (
    input  wire        clk,
    input  wire        reset,
    input  wire        reset_req,
    input  wire [10:0] address,
    input  wire        read,
    input  wire        write,
    output reg  [31:0] readdata,
    input  wire [31:0] writedata,
    input  wire [3:0]  byteenable,
    input  wire        chipselect
);

    wire reset_n = ~reset;

    // ---- Control/status registers ----
    reg         cpu_reset_reg;
    reg         cpu_done;
    reg [31:0]  cpu_result [0:3];

    // CPU stays in reset until host explicitly clears cpu_reset_reg.
    // Delay CPU start by 4 cycles after reset release to let RAM pipeline flush.
    reg [3:0] rst_delay;
    always @(posedge clk) begin
        if (reset | cpu_reset_reg)
            rst_delay <= 4'hF;
        else if (rst_delay != 0)
            rst_delay <= rst_delay - 1;
    end
    wire cpu_rst = (rst_delay != 0);

    // ---- On-chip RAM (4 KB) — explicit dual-port for Quartus ----
    // Port A: instruction fetch (read-only)
    // Port B: data bus + PCIe (read/write)
    // (dual-port RAM declared below as dpram[])

    // ---- VexRiscv buses ----
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

    // ---- CFU bus (internal) ----
    wire        cfu_cmd_valid, cfu_cmd_ready;
    wire [2:0]  cfu_cmd_function_id;
    wire [31:0] cfu_cmd_inputs_0, cfu_cmd_inputs_1;
    wire        cfu_rsp_valid, cfu_rsp_ready;
    wire [31:0] cfu_rsp_outputs_0;

    // ---- VexRiscv core ----
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

    // ---- Custom Function Unit ----
    ldx_cfu cfu (
        .clk(clk), .reset(cpu_rst),
        .cmd_valid(cfu_cmd_valid), .cmd_ready(cfu_cmd_ready),
        .cmd_function_id(cfu_cmd_function_id),
        .cmd_inputs_0(cfu_cmd_inputs_0), .cmd_inputs_1(cfu_cmd_inputs_1),
        .rsp_valid(cfu_rsp_valid), .rsp_ready(cfu_rsp_ready),
        .rsp_outputs_0(cfu_rsp_outputs_0)
    );

    // ---- Bus signals ----
    wire dbus_is_ram = (dbus_cmd_payload_address[31:28] == 4'h8);
    wire dbus_is_io  = (dbus_cmd_payload_address[31:28] == 4'hF);

    assign ibus_cmd_ready = 1'b1;
    assign dbus_cmd_ready = 1'b1;

    // ---- Dual-port RAM using altsyncram (Quartus native, guaranteed dual-port) ----
    // Port A: instruction fetch (read-only)
    // Port B: data bus + PCIe (read/write)

    wire        pcie_ram_wr = chipselect && write && (address < 11'h400) && cpu_reset_reg;
    wire        cpu_ram_wr  = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_ram && !cpu_rst;
    wire        ram_b_we    = pcie_ram_wr || cpu_ram_wr;
    wire [9:0]  ram_b_addr  = cpu_reset_reg ? address[9:0] : dbus_cmd_payload_address[11:2];
    wire [31:0] ram_b_wdata = cpu_reset_reg ? writedata : dbus_cmd_payload_data;
    wire [9:0]  ram_b_raddr = cpu_rst ? address[9:0] : dbus_cmd_payload_address[11:2];

    wire [31:0] ram_a_q;  // Port A read data
    wire [31:0] ram_b_q;  // Port B read data

`ifndef SIMULATION
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),
        .width_a(32),
        .widthad_a(10),
        .numwords_a(1024),
        .width_b(32),
        .widthad_b(10),
        .numwords_b(1024),
        .outdata_reg_a("CLOCK0"),
        .outdata_reg_b("CLOCK0"),
        .address_aclr_b("NONE"),
        .outdata_aclr_b("NONE"),
        .read_during_write_mode_mixed_ports("DONT_CARE"),
        .power_up_uninitialized("FALSE"),
        .intended_device_family("Cyclone IV GX")
    ) ram (
        .clock0(clk),
        // Port A: instruction fetch (read-only)
        .address_a(ibus_cmd_payload_pc[11:2]),
        .data_a(32'd0),
        .wren_a(1'b0),
        .q_a(ram_a_q),
        // Port B: data bus + PCIe (read/write)
        .address_b(ram_b_we ? ram_b_addr : ram_b_raddr),
        .data_b(ram_b_wdata),
        .wren_b(ram_b_we),
        .q_b(ram_b_q),
        // Clock and enables
        .clock1(clk),
        .clocken0(1'b1), .clocken1(1'b1),
        .clocken2(1'b1), .clocken3(1'b1),
        .aclr0(1'b0), .aclr1(1'b0),
        .addressstall_a(1'b0), .addressstall_b(1'b0),
        .byteena_a(1'b1), .byteena_b(1'b1),
        .rden_a(1'b1), .rden_b(1'b1),
        .eccstatus()
    );

`else
    // Behavioral dual-port RAM for simulation
    reg [31:0] dpram [0:1023];
    reg [31:0] ram_a_q_r, ram_a_q_r2, ram_b_q_r;
    always @(posedge clk) begin
        ram_a_q_r <= dpram[ibus_cmd_payload_pc[11:2]];
        ram_a_q_r2 <= ram_a_q_r;  // 2-cycle latency to match altsyncram + output reg
    end
    reg [31:0] ram_b_q_r2;
    always @(posedge clk) begin
        ram_b_q_r <= dpram[ram_b_we ? ram_b_addr : ram_b_raddr];
        ram_b_q_r2 <= ram_b_q_r;  // 2-cycle latency
        if (ram_b_we) dpram[ram_b_addr] <= ram_b_wdata;
    end
    assign ram_a_q = ram_a_q_r2;
    assign ram_b_q = ram_b_q_r2;
`endif

    // Port A → instruction bus (2-cycle latency: M9K + output register)
    assign ibus_rdata = ram_a_q;
    reg ibus_rsp_valid_d1;
    always @(posedge clk) begin
        ibus_rsp_valid_d1 <= ibus_cmd_valid & !cpu_rst;
        ibus_rsp_valid_r <= ibus_rsp_valid_d1;
    end

    // Port B → data bus / PCIe reads (2-cycle latency to match CLOCK0 output reg)
    reg dbus_rsp_valid_d1;
    always @(posedge clk) begin
        dbus_rsp_valid_d1 <= dbus_cmd_valid & !dbus_cmd_payload_wr & !cpu_rst;
        dbus_rsp_valid_r <= dbus_rsp_valid_d1;
    end
    always @(*) dbus_rdata = ram_b_q;

    // ---- I/O + control registers (separate from RAM) ----
    always @(posedge clk) begin
        if (dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_io && !cpu_rst) begin
            case (dbus_cmd_payload_address[7:0])
                8'h00: cpu_result[0] <= dbus_cmd_payload_data;
                8'h04: cpu_done <= 1'b1;
                8'h08: cpu_result[1] <= dbus_cmd_payload_data;
                8'h0C: cpu_result[2] <= dbus_cmd_payload_data;
                8'h10: cpu_result[3] <= dbus_cmd_payload_data;
            endcase
        end

        if (reset) begin
            cpu_reset_reg <= 1'b1;
            cpu_done <= 1'b0;
        end else if (chipselect && write && address == 11'h7C0) begin
            cpu_reset_reg <= writedata[0];
            if (!writedata[0]) cpu_done <= 1'b0;
        end
    end

    // Read output (readLatency=1: registered)
    // Address is sampled on cycle N, data appears on cycle N+1.
    // RAM reads: altsyncram handles the 1-cycle latency internally.
    // Control registers: we register them to match.
    // readLatency=2: pipeline address through 2 stages
    reg [10:0] addr_r1, addr_r2;
    always @(posedge clk) begin
        addr_r1 <= address;
        addr_r2 <= addr_r1;
    end

    always @(*) begin
        if (addr_r2 < 11'h400)
            readdata = ram_b_q;
        else case (addr_r2)
            11'h7C0: readdata = {31'd0, cpu_reset_reg};
            11'h7C1: readdata = {31'd0, cpu_done};
            11'h7C2: readdata = cpu_result[0];
            11'h7C3: readdata = cpu_result[1];
            11'h7C4: readdata = cpu_result[2];
            11'h7C5: readdata = cpu_result[3];
            11'h7E0: readdata = 32'h4C445832;  // "LDX2"
            default: readdata = 32'd0;
        endcase
    end

endmodule
