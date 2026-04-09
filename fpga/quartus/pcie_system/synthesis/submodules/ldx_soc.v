// ldx_soc.v — thin Verilog shim that instantiates the VHDL arv_soc.
//
// QSYS instantiates `ldx_soc` by name in pcie_system/synthesis/pcie_system.v.
// This file keeps the module name and port shape unchanged so the QSYS
// system needs no regeneration; the implementation underneath is now
// the ARV (asynchronous RISC-V) CPU instead of VexRiscv.
//
// The previous VexRiscv-based version is preserved alongside as
// ldx_soc.v.vexriscv.bak — restore it to revert.

module ldx_soc (
    input  wire        clk,
    input  wire        reset,
    input  wire        reset_req,
    input  wire [10:0] address,
    input  wire        read,
    input  wire        write,
    output wire [31:0] readdata,
    input  wire [31:0] writedata,
    input  wire [3:0]  byteenable,
    input  wire        chipselect
);

    arv_soc u_arv_soc (
        .clk(clk),
        .reset(reset),
        .reset_req(reset_req),
        .address(address),
        .read(read),
        .write(write),
        .readdata(readdata),
        .writedata(writedata),
        .byteenable(byteenable),
        .chipselect(chipselect)
    );

endmodule
