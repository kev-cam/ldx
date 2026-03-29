# pcie_system.tcl — Generate Platform Designer system for DE2i-150 PCIe.
#
# Usage:
#   cd fpga/quartus
#   qsys-script --script=pcie_system.tcl
#   qsys-generate pcie_system.qsys --synthesis=VERILOG
#
# The PCIe hard IP acts as a bus master on BAR0: when the Atom writes to
# the PCIe BAR, the hard IP issues an Avalon-MM write to our slave.

package require -exact qsys 16.0

create_system "pcie_system"
set_project_property DEVICE_FAMILY "Cyclone IV GX"
set_project_property DEVICE EP4CGX150DF31C7

# ---- PCIe Hard IP (Cyclone IV GX) ----
add_instance pcie altera_pcie_hard_ip

# x1 Gen1
set_instance_parameter_value pcie {max_link_width} {1}
set_instance_parameter_value pcie {CB_PCIE_MODE} {0}

# PCI IDs
set_instance_parameter_value pcie {vendor_id} {4466}
set_instance_parameter_value pcie {device_id} {57345}
set_instance_parameter_value pcie {subsystem_vendor_id} {4466}
set_instance_parameter_value pcie {subsystem_device_id} {4}

# BAR0: 8KB (size_mask=13 → 2^13 = 8KB)
set_instance_parameter_value pcie {bar0_io_space} {false}
set_instance_parameter_value pcie {bar0_64bit_mem_space} {false}
set_instance_parameter_value pcie {bar0_prefetchable} {false}
set_instance_parameter_value pcie {bar0_size_mask} {13}

# ---- LDX VexRiscv SoC (VexRiscv + CFU + RAM) ----
add_instance accel ldx_soc

# BAR master → accelerator slave
add_connection pcie.bar1_0 accel.s1

# Clock and reset
add_connection pcie.pcie_core_clk accel.clk1
add_connection pcie.pcie_core_reset accel.reset1

# ---- Exports (top-level ports) ----
# PCIe reference clock (100 MHz from board)
add_interface refclk conduit end
set_interface_property refclk EXPORT_OF pcie.refclk

# PCIe serial lanes
add_interface rx_in conduit end
set_interface_property rx_in EXPORT_OF pcie.rx_in

add_interface tx_out conduit end
set_interface_property tx_out EXPORT_OF pcie.tx_out

# PCIe reset
add_interface pcie_rstn conduit end
set_interface_property pcie_rstn EXPORT_OF pcie.pcie_rstn

# fixedclk: loop PCIe core clock back (as per Terasic reference design)
add_connection pcie.pcie_core_clk pcie.fixedclk

# cal_blk_clk and reconfig_gxbclk: export for external 50MHz
add_interface cal_blk_clk clock end
set_interface_property cal_blk_clk EXPORT_OF pcie.cal_blk_clk

add_interface reconfig_gxbclk clock end
set_interface_property reconfig_gxbclk EXPORT_OF pcie.reconfig_gxbclk

# Reconfig interfaces: export (left unconnected externally, as per reference)
add_interface reconfig_togxb conduit end
set_interface_property reconfig_togxb EXPORT_OF pcie.reconfig_togxb

add_interface reconfig_fromgxb_0 conduit end
set_interface_property reconfig_fromgxb_0 EXPORT_OF pcie.reconfig_fromgxb_0

# Core clock (output — for user logic)
add_interface core_clk clock start
set_interface_property core_clk EXPORT_OF pcie.pcie_core_clk

# Core reset
add_interface core_reset reset start
set_interface_property core_reset EXPORT_OF pcie.pcie_core_reset

# Test input (active-low)
add_interface test_in conduit end
set_interface_property test_in EXPORT_OF pcie.test_in

save_system "pcie_system.qsys"
puts "PCIe system saved as pcie_system.qsys"
puts "Next: qsys-generate pcie_system.qsys --synthesis=VERILOG"
