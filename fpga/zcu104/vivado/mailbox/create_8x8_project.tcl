# create_8x8_project.tcl — create the ZCU104 project for the 8x8 mailbox mesh:
# the PL array (mb_array_top = mb_array_soc + AXI4-Lite slave) driven by the
# Zynq UltraScale+ PS over AXI. Run:  vivado -mode batch -source create_8x8_project.tcl
#
# NB: untested in this env (no Vivado). The block-design automation calls are
# version-sensitive — if apply_bd_automation rule names differ on your Vivado,
# adjust them. synth_8x8.tcl needs NONE of this (pure OOC synth for utilization).

set script_dir [file dirname [file normalize [info script]]]
set proj_name  zcu104_mb8x8
set proj_dir   "$script_dir/build/$proj_name"
set part  xczu7ev-ffvc1156-2-e
set board xilinx.com:zcu104:part0:1.1     ;# adjust to your installed board rev
set mb    /usr/local/src/ldx/fpga/zcu104/rtl/mailbox
set rtl   /usr/local/src/ldx/fpga/rtl

create_project $proj_name $proj_dir -part $part -force
catch { set_property board_part $board [current_project] }

add_files -norecurse [list \
  $mb/mailbox_pkg.sv $mb/mb_slot_file.sv $mb/mb_nif.sv $mb/mb_router.sv \
  $mb/mb_mesh.sv $mb/mb_barrier.sv $mb/ldx_soc_mailbox.v $mb/mb_array_soc.v \
  $rtl/VexRiscv.v $mb/m1/ldx_cfu_stub.v $script_dir/mb_array_top.v ]
foreach f [get_files *.sv] { set_property file_type "SystemVerilog" $f }
update_compile_order -fileset sources_1

# ---- block design: PS + mb_array_top over AXI4-Lite ---------------------
create_bd_design system
create_bd_cell -type ip -vlnv [lindex [get_ipdefs *zynq_ultra_ps_e*] 0] ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
  -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__FABRIC__RST {1}] [get_bd_cells ps]

create_bd_cell -type module -reference mb_array_top arr
# connect the PS AXI master to arr/s_axi (adds SmartConnect + clk/reset)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config [list Master {/ps/M_AXI_HPM0_FPD} Clk {Auto}] [get_bd_intf_pins arr/s_axi]

regenerate_bd_layout
validate_bd_design
set bd [get_files system.bd]
make_wrapper -files $bd -top
add_files -norecurse [glob -nocomplain $proj_dir/$proj_name.gen/sources_1/bd/system/hdl/system_wrapper.*]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "## project created: $proj_dir   (top = system_wrapper)"
puts "## next:  vivado -mode batch -source build_8x8.tcl"
