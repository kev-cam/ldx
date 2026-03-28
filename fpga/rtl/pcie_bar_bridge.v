// pcie_bar_bridge.v — PCIe BAR0 to Avalon-MM bridge for DE2i-150.
//
// The Cyclone IV GX has a PCIe hard IP block.  This module sits between
// the hard IP's Avalon-MM master interface and the accelerator slot(s).
//
// BAR0 layout (8 KB, as seen by the Atom over PCIe):
//   0x0000..0x00FF:  Slot 0 registers (args + result + status)
//   0x0100..0x01FF:  Slot 1 registers (future)
//   ...
//   0x1F00..0x1FFF:  Global control/status
//     0x1F00:  magic   (read: 0x4C445831 = "LDX1")
//     0x1F04:  version (read: 0x00010000 = 1.0.0)
//     0x1F08:  n_slots (read: number of active accelerator slots)
//     0x1F0C:  slot 0 function ID (read/write)
//
// Each slot gets 256 bytes = 64 × 32-bit registers.

module pcie_bar_bridge #(
    parameter N_SLOTS = 1
) (
    input  wire        clk,
    input  wire        reset_n,

    // From PCIe hard IP (Avalon-MM slave port — directly memory-mapped to BAR0)
    input  wire [12:0] pcie_address,    // byte address within BAR0 (8KB)
    input  wire        pcie_read,
    input  wire        pcie_write,
    input  wire [31:0] pcie_writedata,
    input  wire [3:0]  pcie_byteenable,
    output reg  [31:0] pcie_readdata,
    output wire        pcie_waitrequest,

    // To accelerator slot 0
    output wire [5:0]  slot0_address,
    output wire        slot0_read,
    output wire        slot0_write,
    output wire [31:0] slot0_writedata,
    input  wire [31:0] slot0_readdata,
    input  wire        slot0_waitrequest
);

    // Decode: top bits select slot vs. global, bottom bits are register offset
    wire [4:0]  slot_sel   = pcie_address[12:8];  // slot index (0..30) or 0x1F=global
    wire [5:0]  reg_offset = pcie_address[7:2];    // word offset within slot

    wire is_global = (slot_sel == 5'h1F);
    wire is_slot0  = (slot_sel == 5'h00);

    // Slot 0 passthrough
    assign slot0_address   = reg_offset;
    assign slot0_read      = pcie_read  & is_slot0;
    assign slot0_write     = pcie_write & is_slot0;
    assign slot0_writedata = pcie_writedata;

    // No wait states for now
    assign pcie_waitrequest = is_slot0 ? slot0_waitrequest : 1'b0;

    // Global registers
    reg [31:0] slot0_func_id;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            slot0_func_id <= 32'd0;
        else if (pcie_write && is_global && reg_offset == 6'h03)
            slot0_func_id <= pcie_writedata;
    end

    // Read mux
    always @(*) begin
        if (is_slot0)
            pcie_readdata = slot0_readdata;
        else if (is_global) begin
            case (reg_offset)
                6'h00:   pcie_readdata = 32'h4C445831;  // "LDX1"
                6'h01:   pcie_readdata = 32'h00010000;  // version 1.0.0
                6'h02:   pcie_readdata = N_SLOTS;
                6'h03:   pcie_readdata = slot0_func_id;
                default: pcie_readdata = 32'd0;
            endcase
        end else
            pcie_readdata = 32'd0;
    end

endmodule
