# ldx_soc_hw.tcl — QSYS component: VexRiscv SoC with CFU.

package require -exact qsys 16.0

set_module_property NAME ldx_soc
set_module_property DISPLAY_NAME "LDX VexRiscv SoC"
set_module_property VERSION 1.0
set_module_property DESCRIPTION "VexRiscv RV32IM + CFU + dual-port RAM"
set_module_property GROUP "LDX"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true

# Source files
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL ldx_soc
add_fileset_file ldx_soc.v VERILOG PATH ldx_soc.v
add_fileset_file VexRiscv.v VERILOG PATH VexRiscv.v
add_fileset_file ldx_cfu.v VERILOG PATH ldx_cfu.v
# c2v accelerator modules (from simulators/verilator/)
add_fileset_file cfu_vl_countones_i.v VERILOG PATH ../../simulators/verilator/cfu_vl_countones_i.v
add_fileset_file cfu_vl_redxor_32.v VERILOG PATH ../../simulators/verilator/cfu_vl_redxor_32.v
add_fileset_file cfu_vl_onehot_i.v VERILOG PATH ../../simulators/verilator/cfu_vl_onehot_i.v
add_fileset_file cfu_vl_onehot0_i.v VERILOG PATH ../../simulators/verilator/cfu_vl_onehot0_i.v
add_fileset_file cfu_vl_bswap32.v VERILOG PATH ../../simulators/verilator/cfu_vl_bswap32.v
add_fileset_file cfu_vl_bitreverse8.v VERILOG PATH ../../simulators/verilator/cfu_vl_bitreverse8.v
add_fileset_file cfu_vl_div_iii.v VERILOG PATH ../../simulators/verilator/cfu_vl_div_iii.v
add_fileset_file cfu_vl_moddiv_iii.v VERILOG PATH ../../simulators/verilator/cfu_vl_moddiv_iii.v

# Clock
add_interface clk1 clock end
set_interface_property clk1 ENABLED true
add_interface_port clk1 clk clk Input 1

# Reset
add_interface reset1 reset end
set_interface_property reset1 ENABLED true
set_interface_property reset1 associatedClock clk1
add_interface_port reset1 reset reset Input 1
add_interface_port reset1 reset_req reset_req Input 1

# Avalon-MM slave
add_interface s1 avalon slave
set_interface_property s1 ENABLED true
set_interface_property s1 associatedClock clk1
set_interface_property s1 associatedReset reset1
set_interface_property s1 addressUnits WORDS
set_interface_property s1 maximumPendingReadTransactions 0
set_interface_property s1 readLatency 1
set_interface_property s1 readWaitTime 0
set_interface_property s1 holdTime 0
set_interface_property s1 setupTime 0
set_interface_property s1 timingUnits Cycles
set_interface_property s1 explicitAddressSpan 8192

add_interface_port s1 address address Input 11
add_interface_port s1 read read Input 1
add_interface_port s1 write write Input 1
add_interface_port s1 readdata readdata Output 32
add_interface_port s1 writedata writedata Input 32
add_interface_port s1 byteenable byteenable Input 4
add_interface_port s1 chipselect chipselect Input 1
