# ldx_accel_slave_hw.tcl — QSYS component for ldx accelerator slave.

package require -exact qsys 16.0

set_module_property NAME ldx_accel_slave
set_module_property DISPLAY_NAME "LDX Accelerator Slave"
set_module_property VERSION 1.0
set_module_property DESCRIPTION "Avalon-MM slave with c2v hardware function accelerator"
set_module_property GROUP "LDX"
set_module_property AUTHOR "ldx"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true

# Source files
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL ldx_accel_slave
add_fileset_file ldx_accel_slave.v VERILOG PATH ldx_accel_slave.v
add_fileset_file add.v VERILOG PATH add.v

# Clock interface
add_interface clk1 clock end
set_interface_property clk1 ENABLED true
add_interface_port clk1 clk clk Input 1

# Reset interface
add_interface reset1 reset end
set_interface_property reset1 ENABLED true
set_interface_property reset1 associatedClock clk1
add_interface_port reset1 reset reset Input 1
add_interface_port reset1 reset_req reset_req Input 1

# Avalon-MM slave interface (matches onchip_mem pattern)
add_interface s1 avalon slave
set_interface_property s1 ENABLED true
set_interface_property s1 associatedClock clk1
set_interface_property s1 associatedReset reset1
set_interface_property s1 addressUnits WORDS
set_interface_property s1 maximumPendingReadTransactions 0
set_interface_property s1 readLatency 0
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
