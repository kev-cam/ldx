// ldx_mesh.v — Parameterizable VexRiscv processor mesh.
//
// Generates an N_ROWS × N_COLS array of VexRiscv cores, each with:
//   - CFU (ldx_cfu) for c2v accelerated functions
//   - Local RAM (dual-port, configurable size)
//   - Register-file FIFOs to adjacent cores (up to 3 neighbors)
//   - Per-core control/status accessible from the host
//
// Host interface: Avalon-MM slave (from PCIe BAR).
// Address map: core_sel[3:0] in upper address bits selects which core.
//
// Parameters:
//   N_ROWS, N_COLS — mesh dimensions (e.g., 2×2)
//   RAM_WORDS      — words per core (e.g., 2048 = 8KB)

module ldx_mesh #(
    parameter N_ROWS   = 1,
    parameter N_COLS   = 1,
    parameter RAM_WORDS = 2048
) (
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

    localparam N_CORES = N_ROWS * N_COLS;
    localparam CORE_BITS = (N_CORES > 1) ? $clog2(N_CORES) : 1;

    // ---- Per-core address decode ----
    // Upper bits of address select core, lower bits are within-core offset.
    // With 8KB BAR and up to 4 cores: bits [10:9] = core_sel, [8:0] = local addr
    wire [CORE_BITS-1:0] core_sel = address[10:10-CORE_BITS+1];
    wire [10-CORE_BITS:0] local_addr = address[10-CORE_BITS:0];

    // ---- Per-core control/status ----
    reg  [N_CORES-1:0] cpu_reset_reg;
    reg  [N_CORES-1:0] cpu_done;
    reg  [31:0] cpu_result [0:N_CORES*4-1];

    // ---- Core instances ----
    genvar r, c;
    generate
        for (r = 0; r < N_ROWS; r = r + 1) begin : row
            for (c = 0; c < N_COLS; c = c + 1) begin : col
                localparam CORE_ID = r * N_COLS + c;

                // Per-core RAM
                reg [31:0] dpram [0:RAM_WORDS-1];

                // VexRiscv buses
                wire        ibus_cmd_valid, ibus_cmd_ready;
                wire [31:0] ibus_cmd_payload_pc;
                reg         ibus_rsp_valid_r;
                wire [31:0] ibus_rdata;
                reg  [31:0] ibus_rdata_r;

                wire        dbus_cmd_valid, dbus_cmd_ready;
                wire        dbus_cmd_payload_wr;
                wire [3:0]  dbus_cmd_payload_mask;
                wire [31:0] dbus_cmd_payload_address;
                wire [31:0] dbus_cmd_payload_data;
                wire [1:0]  dbus_cmd_payload_size;
                reg         dbus_rsp_valid_r;
                reg  [31:0] dbus_rdata;

                // CFU bus
                wire        cfu_cmd_valid, cfu_cmd_ready;
                wire [2:0]  cfu_cmd_function_id;
                wire [31:0] cfu_cmd_inputs_0, cfu_cmd_inputs_1;
                wire        cfu_rsp_valid, cfu_rsp_ready;
                wire [31:0] cfu_rsp_outputs_0;

                wire cpu_rst = reset | cpu_reset_reg[CORE_ID];
                wire dbus_is_ram = (dbus_cmd_payload_address[31:28] == 4'h8);
                wire dbus_is_io  = (dbus_cmd_payload_address[31:28] == 4'hF);

                assign ibus_cmd_ready = 1'b1;
                assign dbus_cmd_ready = 1'b1;
                assign ibus_rdata = ibus_rdata_r;

                // VexRiscv core
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

                // CFU
                ldx_cfu cfu (
                    .clk(clk), .reset(cpu_rst),
                    .cmd_valid(cfu_cmd_valid), .cmd_ready(cfu_cmd_ready),
                    .cmd_function_id(cfu_cmd_function_id),
                    .cmd_inputs_0(cfu_cmd_inputs_0), .cmd_inputs_1(cfu_cmd_inputs_1),
                    .rsp_valid(cfu_rsp_valid), .rsp_ready(cfu_rsp_ready),
                    .rsp_outputs_0(cfu_rsp_outputs_0)
                );

                // Port A: instruction fetch / PCIe read
                localparam RAM_ABITS = $clog2(RAM_WORDS);
                wire [RAM_ABITS-1:0] ram_a_addr = cpu_reset_reg[CORE_ID] ?
                    local_addr[RAM_ABITS-1:0] : ibus_cmd_payload_pc[RAM_ABITS+1:2];

                always @(posedge clk) begin
                    ibus_rdata_r <= dpram[ram_a_addr];
                    ibus_rsp_valid_r <= ibus_cmd_valid & !cpu_rst;
                end

                // Port B: data bus read/write
                wire host_wr = chipselect && write && (core_sel == CORE_ID) &&
                               (local_addr < RAM_WORDS) && cpu_reset_reg[CORE_ID];
                wire cpu_wr  = dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_ram && !cpu_reset_reg[CORE_ID];
                wire ram_b_we = host_wr || cpu_wr;
                wire [RAM_ABITS-1:0] ram_b_addr = cpu_reset_reg[CORE_ID] ?
                    local_addr[RAM_ABITS-1:0] : dbus_cmd_payload_address[RAM_ABITS+1:2];
                wire [31:0] ram_b_wdata = cpu_reset_reg[CORE_ID] ? writedata : dbus_cmd_payload_data;

                always @(posedge clk) begin
                    dbus_rdata <= dpram[dbus_cmd_payload_address[RAM_ABITS+1:2]];
                    dbus_rsp_valid_r <= dbus_cmd_valid & !dbus_cmd_payload_wr & !cpu_rst;
                    if (ram_b_we)
                        dpram[ram_b_addr] <= ram_b_wdata;
                end

                // I/O writes from CPU
                always @(posedge clk) begin
                    if (dbus_cmd_valid && dbus_cmd_payload_wr && dbus_is_io) begin
                        case (dbus_cmd_payload_address[7:0])
                            8'h00: cpu_result[CORE_ID*4 + 0] <= dbus_cmd_payload_data;
                            8'h04: cpu_done[CORE_ID] <= 1'b1;
                            8'h08: cpu_result[CORE_ID*4 + 1] <= dbus_cmd_payload_data;
                            8'h0C: cpu_result[CORE_ID*4 + 2] <= dbus_cmd_payload_data;
                            8'h10: cpu_result[CORE_ID*4 + 3] <= dbus_cmd_payload_data;
                        endcase
                    end
                end

            end  // col
        end  // row
    endgenerate

    // ---- Host control registers ----
    // Global address 0x7C0: core_sel[3:0] + cpu_reset (bit 0)
    // Global address 0x7C1: done bitmap
    // Global address 0x7C2-0x7C5: results for selected core
    // Global address 0x7E0: magic "LDX3"
    // Global address 0x7E1: N_CORES
    // Global address 0x7E2: N_ROWS
    // Global address 0x7E3: N_COLS

    always @(posedge clk) begin
        if (reset) begin
            cpu_reset_reg <= {N_CORES{1'b1}};
            cpu_done <= {N_CORES{1'b0}};
        end else if (chipselect && write) begin
            if (local_addr == 11'h7C0) begin
                // Write bit 0 = reset for selected core
                cpu_reset_reg[core_sel] <= writedata[0];
                if (!writedata[0]) cpu_done[core_sel] <= 1'b0;
            end
        end
    end

    // Host reads
    always @(*) begin
        if (local_addr < RAM_WORDS)
            readdata = dpram[local_addr];  // TODO: fix — needs core-selected read
        else case (local_addr)
            11'h7C0: readdata = {31'd0, cpu_reset_reg[core_sel]};
            11'h7C1: readdata = {{(32-N_CORES){1'b0}}, cpu_done};
            11'h7C2: readdata = cpu_result[core_sel*4 + 0];
            11'h7C3: readdata = cpu_result[core_sel*4 + 1];
            11'h7C4: readdata = cpu_result[core_sel*4 + 2];
            11'h7C5: readdata = cpu_result[core_sel*4 + 3];
            11'h7E0: readdata = 32'h4C445833;  // "LDX3"
            11'h7E1: readdata = N_CORES;
            11'h7E2: readdata = N_ROWS;
            11'h7E3: readdata = N_COLS;
            default: readdata = 32'd0;
        endcase
    end

endmodule
