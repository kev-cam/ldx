## ZCU104 ldx milestone-2: 5x5 mesh of VexRiscv softcores
## ZynqMP HPM0 → SmartConnect → ldx_mesh_bridge → mesh_top.

set script_dir [file dirname [file normalize [info script]]]
set zcu_dir    [file dirname $script_dir]
set repo_root  [file dirname [file dirname $zcu_dir]]

set proj_name   "zcu104_ldx_mesh"
set proj_dir    "$script_dir/build/$proj_name"
set part        "xczu7ev-ffvc1156-2-e"
set board_part  "xilinx.com:zcu104:part0:1.1"
set bd_name     "system"
set rtl_dir     "$zcu_dir/rtl"
set cfu_dir     "$repo_root/simulators/verilator"

file delete -force $proj_dir
create_project $proj_name $proj_dir -part $part
set_property board_part $board_part [current_project]

## --- RTL sources ----------------------------------------------------------
add_files -norecurse [list \
    $rtl_dir/ldx_bd_wrap.v \
    $rtl_dir/ldx_mesh_bridge.v \
    $rtl_dir/mesh_top.v \
    $rtl_dir/ldx_soc_mesh.v \
    $rtl_dir/fifo.v \
    $rtl_dir/ldx_cfu.v \
    $cfu_dir/cfu_vl_bitreverse8.v \
    $cfu_dir/cfu_vl_bswap32.v \
    $cfu_dir/cfu_vl_countones_i.v \
    $cfu_dir/cfu_vl_div_iii.v \
    $cfu_dir/cfu_vl_moddiv_iii.v \
    $cfu_dir/cfu_vl_onehot0_i.v \
    $cfu_dir/cfu_vl_onehot_i.v \
    $cfu_dir/cfu_vl_redxor_32.v \
    $repo_root/fpga/rtl/VexRiscv.v]
update_compile_order -fileset sources_1

## --- Block design ---------------------------------------------------------
create_bd_design $bd_name

create_bd_cell -type ip -vlnv [lindex [get_ipdefs -filter {NAME == zynq_ultra_ps_e}] 0] ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells ps]

## pl_clk0 stays at the 99.999 MHz board default — the multi-cycle divider
## in zcu104/rtl/ldx_cfu.v keeps the combinational path short enough to
## meet timing.

create_bd_cell -type ip -vlnv [lindex [get_ipdefs -filter {NAME == smartconnect}] 0] axi_smc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] \
    [get_bd_cells axi_smc]

## Wrapper that exposes ldx_mesh_bridge + mesh_top as one BD cell.
## Vivado infers the AXI4-Lite interface from s_axi_* port naming.
create_bd_cell -type module -reference ldx_bd_wrap ldx

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI]   [get_bd_intf_pins ldx/s_axi]

connect_bd_net [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins ps/pl_clk0]
connect_bd_net [get_bd_pins ps/maxihpm1_fpd_aclk] [get_bd_pins ps/pl_clk0]
connect_bd_net [get_bd_pins ps/pl_clk0]           [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins ps/pl_clk0]           [get_bd_pins ldx/aclk]

create_bd_cell -type ip -vlnv [lindex [get_ipdefs -filter {NAME == proc_sys_reset}] 0] rst_ps
connect_bd_net [get_bd_pins ps/pl_clk0]                  [get_bd_pins rst_ps/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0]               [get_bd_pins rst_ps/ext_reset_in]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn]   [get_bd_pins axi_smc/aresetn]
connect_bd_net [get_bd_pins rst_ps/peripheral_aresetn]   [get_bd_pins ldx/aresetn]

assign_bd_address

regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files $bd_name.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v
update_compile_order -fileset sources_1
set_property top ${bd_name}_wrapper [current_fileset]

puts "## Address map:"
foreach seg [get_bd_addr_segs -filter {USAGE == register || USAGE == memory}] {
    puts [format "##   %-60s offset=%s range=%s" $seg \
        [get_property OFFSET $seg] [get_property RANGE $seg]]
}
puts "## Project at $proj_dir"
