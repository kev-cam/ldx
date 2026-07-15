# sockit_bench.tcl — Terasic SoCKit Rev D (Cyclone V SX 5CSXFC6D6F31C6) build
# of the mailbox array benchmark harness.  Same board-agnostic top as the DE2i /
# DE10-Nano (de2i_arr_top: self-loader + ISSP readout, only physical pin is
# clk_50), retargeted to Cyclone V SX.  Verified stack: VexRiscv_hsk
# (cmdForkPersistence) + 2-cycle registered-BRAM ldx_soc_mailbox.  prog.mif =
# the cppgen counter (962 words), copied from mbarray_de10nano.
#
# Clock: OSC_50_B5B on PIN_Y26 — fed from the discrete 50 MHz crystal (U36)
# through an SN74AVC1T45 level shifter into bank 5B at HSMC_VCCIO (2.5 V with
# JP2 at its default).  Banks 3B/4A carry the FPGA DDR3 at 1.5 V and their
# 50 MHz inputs come from the Si5338 — avoided (more assumptions).
package require ::quartus::project
project_new sockit_bench -overwrite
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSXFC6D6F31C6
set_global_assignment -name TOP_LEVEL_ENTITY sockit_jtag_top
set mb /usr/local/src/ldx/fpga/zcu104/rtl/mailbox
set_global_assignment -name SEARCH_PATH $mb
foreach f {mailbox_pkg.sv mb_slot_file.sv mb_nif.sv mb_fifo.sv mb_xyrt.sv mb_mesh_hw.sv mb_barrier.sv mb_array_soc.v} {
  set_global_assignment -name SYSTEMVERILOG_FILE $mb/$f
}
set_global_assignment -name SYSTEMVERILOG_FILE $mb/ldx_soc_mailbox.v
set_global_assignment -name VERILOG_FILE /usr/local/src/ldx/fpga/rtl/VexRiscv_hsk.v
set_global_assignment -name VERILOG_FILE $mb/m1/ldx_cfu_stub.v
set_global_assignment -name VERILOG_FILE /usr/local/src/ldx/fpga/quartus/mbarray_sockit/sockit_jtag_top.v
set_global_assignment -name SDC_FILE sockit_wide.sdc
# start at 2x2 (4 cores) — same config as the ZCU104 cppgen-counter test; scale later
set_parameter -name ARRAY_Y 2
set_parameter -name ARRAY_X 2
set_parameter -name NW 1797
set_parameter -name HEXFILE mb_shabench.hex
# SoCKit OSC_50_B5B (bank 5B, HSMC_VCCIO = 2.5 V at JP2 default)
set_location_assignment PIN_Y26 -to clk_50
set_instance_assignment -name IO_STANDARD "2.5 V" -to clk_50
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"
project_close
