// ldx_soc.v — Minimal VexRiscv SoC for FPGA acceleration.
//
// Memory map (from VexRiscv perspective):
//   0x80000000 - 0x80007FFF: On-chip RAM (32 KB, instruction + data)
//   0xF0000000:              Result register (write: store result)
//   0xF0000004:              Status register (write: signal done)
//
// The PCIe host (Atom) can:
//   1. Write program into RAM at 0x80000000 via PCIe BAR
//   2. Release VexRiscv reset
//   3. Poll status register for completion
//   4. Read result registers
//
// PCIe BAR0 layout (8 KB window):
//   0x0000-0x1FFF: First 8KB of on-chip RAM (program + data)
//   0x1F00:        Control: bit 0 = cpu_reset (1=hold, 0=run)
//   0x1F04:        Status: bit 0 = done
//   0x1F08-0x1F1F: Result registers (4 x 32-bit)
//   0x1F80:        Magic (read: "LDX2")

module ldx_soc (
    input  wire        clk,
    input  wire        reset_n,

    // Avalon-MM slave (from PCIe BAR)
    input  wire [10:0] avs_address,
    input  wire        avs_read,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    output reg  [31:0] avs_readdata,
    input  wire [3:0]  avs_byteenable,
    input  wire        avs_chipselect,

    // CFU bus (directly wired to ldx_cfu)
    output wire        cfu_cmd_valid,
    input  wire        cfu_cmd_ready,
    output wire [2:0]  cfu_cmd_function_id,
    output wire [31:0] cfu_cmd_inputs_0,
    output wire [31:0] cfu_cmd_inputs_1,
    input  wire        cfu_rsp_valid,
    output wire        cfu_rsp_ready,
    input  wire [31:0] cfu_rsp_outputs_0
);

    // ---- Control registers ----
    reg         cpu_reset_reg;  // 1 = hold CPU in reset
    reg         cpu_done;
    reg [31:0]  cpu_result [0:3];

    wire cpu_reset = !reset_n | cpu_reset_reg;

    // ---- On-chip RAM (32 KB, dual-port) ----
    // Port A: VexRiscv instruction bus
    // Port B: VexRiscv data bus + PCIe access
    reg [31:0] ram [0:8191];  // 32KB = 8192 x 32-bit

    // ---- VexRiscv buses ----
    // Instruction bus (simple)
    wire        ibus_cmd_valid;
    wire        ibus_cmd_ready;
    wire [31:0] ibus_cmd_payload_pc;
    wire        ibus_rsp_valid;
    wire        ibus_rsp_payload_error;
    wire [31:0] ibus_rsp_payload_inst;

    // Data bus (simple)
    wire        dbus_cmd_valid;
    wire        dbus_cmd_ready;
    wire        dbus_cmd_payload_wr;
    wire [3:0]  dbus_cmd_payload_mask;
    wire [31:0] dbus_cmd_payload_address;
    wire [31:0] dbus_cmd_payload_data;
    wire [1:0]  dbus_cmd_payload_size;
    wire        dbus_rsp_ready;
    wire        dbus_rsp_error;
    wire [31:0] dbus_rsp_data;

    // ---- VexRiscv core ----
    VexRiscv cpu (
        .clk                                    (clk),
        .reset                                  (cpu_reset),
        .timerInterrupt                         (1'b0),
        .externalInterrupt                      (1'b0),
        .softwareInterrupt                      (1'b0),
        // Instruction bus
        .iBus_cmd_valid                         (ibus_cmd_valid),
        .iBus_cmd_ready                         (ibus_cmd_ready),
        .iBus_cmd_payload_pc                    (ibus_cmd_payload_pc),
        .iBus_rsp_valid                         (ibus_rsp_valid),
        .iBus_rsp_payload_error                 (ibus_rsp_payload_error),
        .iBus_rsp_payload_inst                  (ibus_rsp_payload_inst),
        // Data bus
        .dBus_cmd_valid                         (dbus_cmd_valid),
        .dBus_cmd_ready                         (dbus_cmd_ready),
        .dBus_cmd_payload_wr                    (dbus_cmd_payload_wr),
        .dBus_cmd_payload_mask                  (dbus_cmd_payload_mask),
        .dBus_cmd_payload_address               (dbus_cmd_payload_address),
        .dBus_cmd_payload_data                  (dbus_cmd_payload_data),
        .dBus_cmd_payload_size                  (dbus_cmd_payload_size),
        .dBus_rsp_ready                         (dbus_rsp_ready),
        .dBus_rsp_error                         (dbus_rsp_error),
        .dBus_rsp_data                          (dbus_rsp_data),
        // CFU
        .CfuPlugin_bus_cmd_valid                (cfu_cmd_valid),
        .CfuPlugin_bus_cmd_ready                (cfu_cmd_ready),
        .CfuPlugin_bus_cmd_payload_function_id  (cfu_cmd_function_id),
        .CfuPlugin_bus_cmd_payload_inputs_0     (cfu_cmd_inputs_0),
        .CfuPlugin_bus_cmd_payload_inputs_1     (cfu_cmd_inputs_1),
        .CfuPlugin_bus_rsp_valid                (cfu_rsp_valid),
        .CfuPlugin_bus_rsp_ready                (cfu_rsp_ready),
        .CfuPlugin_bus_rsp_payload_outputs_0    (cfu_rsp_outputs_0)
    );

    // ---- Instruction bus: read from RAM ----
    // Address 0x80000000 maps to ram[0]
    wire [12:0] ibus_ram_addr = ibus_cmd_payload_pc[14:2];
    reg ibus_rsp_valid_r;

    assign ibus_cmd_ready = 1'b1;
    assign ibus_rsp_valid = ibus_rsp_valid_r;
    assign ibus_rsp_payload_error = 1'b0;

    reg [31:0] ibus_rdata;
    assign ibus_rsp_payload_inst = ibus_rdata;

    always @(posedge clk) begin
        ibus_rsp_valid_r <= ibus_cmd_valid & !cpu_reset;
        if (ibus_cmd_valid)
            ibus_rdata <= ram[ibus_ram_addr];
    end

    // ---- Data bus: RAM + I/O registers ----
    wire dbus_is_ram = (dbus_cmd_payload_address[31:28] == 4'h8);
    wire dbus_is_io  = (dbus_cmd_payload_address[31:28] == 4'hF);
    wire [12:0] dbus_ram_addr = dbus_cmd_payload_address[14:2];

    assign dbus_cmd_ready = 1'b1;
    assign dbus_rsp_error = 1'b0;

    reg dbus_rsp_valid_r;
    reg [31:0] dbus_rdata;
    assign dbus_rsp_ready = dbus_rsp_valid_r;
    assign dbus_rsp_data = dbus_rdata;

    always @(posedge clk) begin
        dbus_rsp_valid_r <= dbus_cmd_valid & !dbus_cmd_payload_wr & !cpu_reset;
        // RAM read
        if (dbus_cmd_valid && !dbus_cmd_payload_wr && dbus_is_ram)
            dbus_rdata <= ram[dbus_ram_addr];
        // RAM write
        if (dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_ram) begin
            if (dbus_cmd_payload_mask[0]) ram[dbus_ram_addr][ 7: 0] <= dbus_cmd_payload_data[ 7: 0];
            if (dbus_cmd_payload_mask[1]) ram[dbus_ram_addr][15: 8] <= dbus_cmd_payload_data[15: 8];
            if (dbus_cmd_payload_mask[2]) ram[dbus_ram_addr][23:16] <= dbus_cmd_payload_data[23:16];
            if (dbus_cmd_payload_mask[3]) ram[dbus_ram_addr][31:24] <= dbus_cmd_payload_data[31:24];
        end
        // I/O write: result registers and done flag
        if (dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_io) begin
            case (dbus_cmd_payload_address[7:0])
                8'h00: cpu_result[0] <= dbus_cmd_payload_data;
                8'h04: cpu_done <= 1'b1;
                8'h08: cpu_result[1] <= dbus_cmd_payload_data;
                8'h0C: cpu_result[2] <= dbus_cmd_payload_data;
                8'h10: cpu_result[3] <= dbus_cmd_payload_data;
            endcase
        end
    end

    // ---- PCIe slave interface ----
    // Dual-ported: PCIe writes to RAM, reads control/status/results
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_reset_reg <= 1'b1;  // Hold CPU in reset initially
            cpu_done <= 1'b0;
        end else if (avs_chipselect && avs_write) begin
            if (avs_address < 11'h800) begin
                // RAM write (word address 0-0x7FF = byte 0x0000-0x1FFF)
                if (avs_byteenable[0]) ram[avs_address][ 7: 0] <= avs_writedata[ 7: 0];
                if (avs_byteenable[1]) ram[avs_address][15: 8] <= avs_writedata[15: 8];
                if (avs_byteenable[2]) ram[avs_address][23:16] <= avs_writedata[23:16];
                if (avs_byteenable[3]) ram[avs_address][31:24] <= avs_writedata[31:24];
            end else if (avs_address == 11'h7C0) begin
                // Control register
                cpu_reset_reg <= avs_writedata[0];
                if (!avs_writedata[0]) cpu_done <= 1'b0;  // Clear done on run
            end
        end
    end

    // PCIe read
    always @(*) begin
        if (avs_address < 11'h800)
            avs_readdata = ram[avs_address];
        else case (avs_address)
            11'h7C0: avs_readdata = {31'd0, cpu_reset_reg};  // Control
            11'h7C1: avs_readdata = {31'd0, cpu_done};       // Status
            11'h7C2: avs_readdata = cpu_result[0];            // Result 0
            11'h7C3: avs_readdata = cpu_result[1];            // Result 1
            11'h7C4: avs_readdata = cpu_result[2];            // Result 2
            11'h7C5: avs_readdata = cpu_result[3];            // Result 3
            11'h7E0: avs_readdata = 32'h4C445832;            // Magic "LDX2"
            default: avs_readdata = 32'd0;
        endcase
    end

endmodule
