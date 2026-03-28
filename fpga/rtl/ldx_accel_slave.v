// ldx_accel_slave.v — Avalon-MM slave: accelerator with c2v function.
//
// Drop-in replacement for onchip_mem in the PCIe QSYS system.
// Same Avalon-MM slave interface (address, chipselect, write, etc.)
//
// Register map (word-addressed, address[10:0]):
//   0x000-0x007: Slot 0 arg registers (arg[0..7], 32-bit each)
//   0x010:       Slot 0 result low  (read-only)
//   0x011:       Slot 0 result high (read-only, for 64-bit returns)
//   0x012:       Slot 0 status      (read-only, bit 0 = valid)
//   0x7C0:       Magic    (read: 0x4C445831 = "LDX1")
//   0x7C1:       Version  (read: 0x00010000)
//   0x7C2:       N_slots  (read: 1)

module ldx_accel_slave (
    input  wire        clk,
    input  wire        reset,
    input  wire        reset_req,
    input  wire [10:0] address,    // word address (0..2047)
    input  wire        chipselect,
    input  wire        read,
    input  wire        write,
    output reg  [31:0] readdata,
    input  wire [31:0] writedata,
    input  wire [3:0]  byteenable
);

    wire reset_n = ~reset;

    // ---- Argument registers ----
    reg [31:0] arg_reg [0:7];

    // ---- c2v function: add(int a, int b) → int ----
    wire signed [31:0] result;
    add u_add (
        .a      (arg_reg[0]),
        .b      (arg_reg[1]),
        .result (result)
    );

    // ---- Write logic ----
    integer i;
    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < 8; i = i + 1)
                arg_reg[i] <= 32'd0;
        end else if (chipselect && write) begin
            // Slot 0 args at word addresses 0x000-0x007
            if (address < 11'd8)
                arg_reg[address[2:0]] <= writedata;
        end
    end

    // ---- Read logic ----
    always @(*) begin
        if (address < 11'd8)
            readdata = arg_reg[address[2:0]];
        else case (address)
            11'h010: readdata = result;           // result low
            11'h011: readdata = 32'd0;            // result high
            11'h012: readdata = 32'd1;            // status: valid
            11'h7C0: readdata = 32'h4C445831;     // "LDX1"
            11'h7C1: readdata = 32'h00010000;     // version 1.0
            11'h7C2: readdata = 32'd1;            // 1 slot
            default: readdata = 32'd0;
        endcase
    end

endmodule
