## ZCU104 ldx milestone-1: single VexRiscv softcore as AXI4-Lite peripheral
## Target: XCZU7EV on the ZCU104 v1.1 board.

set script_dir [file dirname [file normalize [info script]]]
set zcu_dir    [file dirname $script_dir]
set repo_root  [file dirname [file dirname $zcu_dir]]

set proj_name   "zcu104_ldx_m1"
set proj_dir    "$script_dir/build/$proj_name"
set part        "xczu7ev-ffvc1156-2-e"
set board_part  "xilinx.com:zcu104:part0:1.1"
set bd_name     "system"
set rtl_dir     "$zcu_dir/rtl"
set sim_dir     "$zcu_dir/sim"
set cfu_dir     "$repo_root/simulators/verilator"

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property board_part $board_part [current_project]

## --- RTL sources ----------------------------------------------------------
add_files -norecurse [list \
    $rtl_dir/ldx_soc_axi.v \
    $repo_root/fpga/rtl/VexRiscv.v \
    $repo_root/fpga/rtl/ldx_cfu.v \
    $cfu_dir/cfu_vl_bitreverse8.v \
    $cfu_dir/cfu_vl_bswap32.v \
    $cfu_dir/cfu_vl_countones_i.v \
    $cfu_dir/cfu_vl_div_iii.v \
    $cfu_dir/cfu_vl_moddiv_iii.v \
    $cfu_dir/cfu_vl_onehot0_i.v \
    $cfu_dir/cfu_vl_onehot_i.v \
    $cfu_dir/cfu_vl_redxor_32.v]
update_compile_order -fileset sources_1

## --- Block design ---------------------------------------------------------
create_bd_design $bd_name

create_bd_cell -type ip -vlnv [lindex [get_ipdefs -filter {NAME == zynq_ultra_ps_e}] 0] ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps]

## SmartConnect: HPM0_FPD master → ldx softcore slave
create_bd_cell -type ip -vlnv [lindex [get_ipdefs -filter {NAME == smartconnect}] 0] axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] \
    [get_bd_cells axi_smc]

## Instantiate the softcore SoC module from the RTL sources
create_bd_cell -type module -reference ldx_soc_axi ldx_soc

## Wire AXI master → SmartConnect → ldx_soc
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD]    [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI]      [get_bd_intf_pins ldx_soc/s_axi]

## Clock and reset
connect_bd_net [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins ps/pl_clk0]
connect_bd_net [get_bd_pins ps/maxihpm1_fpd_aclk] [get_bd_pins ps/pl_clk0]
connect_bd_net [get_bd_pins ps/pl_clk0]           [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins ps/pl_clk0]           [get_bd_pins ldx_soc/aclk]

create_bd_cell -type ip -vlnv [lindex [get_ipdefs -filter {NAME == proc_sys_reset}] 0] rst_ps
connect_bd_net [get_bd_pins ps/pl_clk0]                  [get_bd_pins rst_ps/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0]               [get_bd_pins rst_ps/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn]   [get_bd_pins axi_smc/aresetn]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn]   [get_bd_pins ldx_soc/aresetn]

## Expose hypercall_pending as an IRQ to the PS (optional; daemon will poll first)
##   left disconnected for milestone 1.

## Auto address — assigns 8 KB slave somewhere in PS view (typically 0xA0000000 by default)
assign_bd_address

regenerate_bd_layout
validate_bd_design
save_bd_design

## HDL wrapper
make_wrapper -files [get_files $bd_name.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v
update_compile_order -fileset sources_1
set_property top ${bd_name}_wrapper [current_fileset]

## Print the assigned address so the userspace daemon knows where to mmap
puts "## ----------------------------------------"
puts "## Address map:"
foreach seg [get_bd_addr_segs -filter {USAGE == register || USAGE == memory}] {
    set range [get_property RANGE $seg]
    set offset [get_property OFFSET $seg]
    puts [format "##   %-50s offset=%s range=%s" $seg $offset $range]
}
puts "## ----------------------------------------"
puts "## Project created at $proj_dir"
puts "## Next: launch_runs synth_1 -jobs N ; wait_on_run synth_1 ;"
puts "##       launch_runs impl_1 -to_step write_bitstream -jobs N ; wait_on_run impl_1"
