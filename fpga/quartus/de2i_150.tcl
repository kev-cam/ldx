# de2i_150.tcl — Create Quartus project for ldx on DE2i-150.
#
# Usage:
#   cd fpga/quartus
#   quartus_sh -t de2i_150.tcl
#
# This creates the project, sets device/pin assignments, and adds source files.

package require ::quartus::project
package require ::quartus::flow

set project_name "ldx_accel"

# Create project
if {[project_exists $project_name]} {
    project_open $project_name
} else {
    project_new $project_name
}

# ---- Device ----
set_global_assignment -name FAMILY "Cyclone IV GX"
set_global_assignment -name DEVICE EP4CGX150DF31C7
set_global_assignment -name TOP_LEVEL_ENTITY ldx_top

# ---- Source files ----
set_global_assignment -name VERILOG_FILE ../rtl/ldx_top.v
set_global_assignment -name VERILOG_FILE ../rtl/pcie_bar_bridge.v
set_global_assignment -name VERILOG_FILE ../rtl/accel_slot.v
# The c2v-generated module is added here by the build flow:
# set_global_assignment -name VERILOG_FILE ../rtl/accel_func.v

# ---- Timing ----
set_global_assignment -name SDC_FILE de2i_150.sdc

# ---- PCIe pin assignments (DE2i-150) ----
# PCIe reference clock (100 MHz, directly to hard IP)
set_location_assignment PIN_W12 -to pcie_refclk
set_instance_assignment -name IO_STANDARD "1.5-V PCML" -to pcie_refclk

# PCIe reset (directly active-low from Atom)
set_location_assignment PIN_AA26 -to pcie_perstn
set_instance_assignment -name IO_STANDARD "2.5 V" -to pcie_perstn

# PCIe data lanes (directly routed to hard IP transceiver)
set_location_assignment PIN_AD28 -to pcie_rx
set_instance_assignment -name IO_STANDARD "1.5-V PCML" -to pcie_rx
set_location_assignment PIN_AD27 -to pcie_tx
set_instance_assignment -name IO_STANDARD "1.5-V PCML" -to pcie_tx

# ---- LED pin assignments (active low on DE2i-150) ----
set_location_assignment PIN_G19 -to led[0]
set_location_assignment PIN_F19 -to led[1]
set_location_assignment PIN_E19 -to led[2]
set_location_assignment PIN_F21 -to led[3]
set_location_assignment PIN_F18 -to led[4]
set_location_assignment PIN_E18 -to led[5]
set_location_assignment PIN_J19 -to led[6]
set_location_assignment PIN_H19 -to led[7]

set_instance_assignment -name IO_STANDARD "2.5 V" -to led[*]

# ---- Fitter settings ----
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"
set_global_assignment -name STRATIX_DEVICE_IO_STANDARD "2.5 V"
set_global_assignment -name OPTIMIZE_HOLD_TIMING "ALL PATHS"
set_global_assignment -name OPTIMIZE_MULTI_CORNER_TIMING ON
set_global_assignment -name FITTER_EFFORT "STANDARD FIT"

# ---- PCIe Hard IP settings ----
# The actual PCIe IP is configured through Platform Designer (QSYS).
# These are the key parameters for DE2i-150:
#   - Variant: Cyclone IV GX Hard IP for PCI Express
#   - Lanes: x1
#   - Gen: 1
#   - BAR0: 8KB (non-prefetchable, 32-bit)
#   - Vendor ID: 0x1172 (Altera)
#   - Device ID: 0xE001

set_global_assignment -name ENABLE_SIGNALTAP OFF

project_close
puts "Project '$project_name' created successfully."
puts "Next: configure PCIe hard IP via Platform Designer, then run compilation."
