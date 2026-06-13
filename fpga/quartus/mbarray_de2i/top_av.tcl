package require ::quartus::project
project_new de2i_av_top -overwrite
set_global_assignment -name FAMILY "Cyclone IV GX"
set_global_assignment -name DEVICE EP4CGX150DF31C7
set_global_assignment -name TOP_LEVEL_ENTITY de2i_av_top
set_global_assignment -name VERILOG_FILE /usr/local/src/ldx/fpga/rtl/VexRiscv.v
set_global_assignment -name VERILOG_FILE ldx_de2i_soc.v
set_global_assignment -name VERILOG_FILE de2i_av_top.v
set_global_assignment -name SDC_FILE de2i.sdc
set_location_assignment PIN_AJ16 -to clk_50
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to clk_50
set_global_assignment -name RESERVE_ALL_UNUSED_PINS_WEAK_PULLUP "AS INPUT TRI-STATED"
project_close
