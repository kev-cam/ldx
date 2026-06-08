# create_8x8_project.tcl — ZCU104 project for the 8x8 mailbox mesh: PL array
# (mb_array_top = mb_array_soc + AXI4-Lite slave) driven by the Zynq US+ PS.
# Run: vivado -mode batch -source create_8x8_project.tcl
# Explicit BD wiring (no apply_bd_automation for the AXI path — that left the
# clock unconnected on 2025.2). Verified to build the project on Vivado 2025.2.

set script_dir [file dirname [file normalize [info script]]]
set proj_name  zcu104_mb8x8
set proj_dir   "$script_dir/build/$proj_name"
set part  xczu7ev-ffvc1156-2-e
set board xilinx.com:zcu104:part0:1.1
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

proc ipdef {pat} { return [lindex [get_ipdefs $pat] 0] }

create_bd_design system

# ---- PS: board preset, one FPD AXI master, a 200 MHz PL clock + PL reset ----
set ps [create_bd_cell -type ip -vlnv [ipdef *zynq_ultra_ps_e*] ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} $ps
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} ] $ps

# ---- the array (8 KB/core: 128 BRAM36 = 41%, leaves placement margin) -------
create_bd_cell -type module -reference mb_array_top arr
set_property CONFIG.MEM_WORDS {2048} [get_bd_cells arr]

# ---- interconnect + reset ---------------------------------------------------
set sc  [create_bd_cell -type ip -vlnv [ipdef xilinx.com:ip:smartconnect:*] sc]
set_property CONFIG.NUM_SI {1} $sc
set rst [create_bd_cell -type ip -vlnv [ipdef xilinx.com:ip:proc_sys_reset:*] rst]

# ---- clocks + resets (explicit) ---------------------------------------------
connect_bd_net [get_bd_pins ps/pl_clk0] \
  [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins sc/aclk] \
  [get_bd_pins arr/s_axi_aclk] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] \
  [get_bd_pins sc/aresetn] [get_bd_pins arr/s_axi_aresetn]

# ---- AXI: PS M_AXI_HPM0_FPD -> smartconnect -> arr/s_axi --------------------
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI]        [get_bd_intf_pins arr/s_axi]
assign_bd_address

regenerate_bd_layout
validate_bd_design
set bd [get_files system.bd]
make_wrapper -files $bd -top
add_files -norecurse [glob -nocomplain $proj_dir/$proj_name.gen/sources_1/bd/system/hdl/system_wrapper.*]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
puts "## project created: $proj_dir   (top = system_wrapper)"
puts "## next:  vivado -mode batch -source build_8x8.tcl"
