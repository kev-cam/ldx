# synth_8x8.tcl — out-of-context synthesis of the mailbox mesh array on the
# ZCU104 (xczu7ev), to get REAL LUT/FF/BRAM/DSP and a timing estimate. No PS;
# just the PL array logic (which dominates). Mirrors the old synth_mesh10.tcl.
#
# Usage: vivado -mode batch -source synth_8x8.tcl -tclargs [AY] [AX] [MEM_WORDS] [PERIOD_NS]
#   default 8 8 4096 5.0  (8x8 = 64 cores, 16 KB/core, 200 MHz target)

set AY     [lindex $argv 0]; if {$AY eq ""}     {set AY 8}
set AX     [lindex $argv 1]; if {$AX eq ""}     {set AX 8}
set MW     [lindex $argv 2]; if {$MW eq ""}     {set MW 4096}
set PERIOD [lindex $argv 3]; if {$PERIOD eq ""} {set PERIOD 5.0}

set part xczu7ev-ffvc1156-2-e
set mb   /usr/local/src/ldx/fpga/zcu104/rtl/mailbox
set rtl  /usr/local/src/ldx/fpga/rtl

# package first, then the SV fabric, then the plain-Verilog core + CFU stub
read_verilog -sv $mb/mailbox_pkg.sv
read_verilog -sv [list \
  $mb/mb_slot_file.sv $mb/mb_nif.sv $mb/mb_router.sv $mb/mb_mesh.sv \
  $mb/mb_fifo.sv $mb/mb_xyrt.sv $mb/mb_mesh_hw.sv $mb/mb_barrier.sv $mb/ldx_soc_mailbox.v $mb/mb_array_soc.v ]
read_verilog [list $rtl/VexRiscv.v $mb/m1/ldx_cfu_stub.v ]

synth_design -top mb_array_soc -part $part -mode out_of_context \
  -generic ARRAY_Y=$AY -generic ARRAY_X=$AX -generic USE_MESH=0 -generic USE_HWROUTER=1 \
  -generic HOST_INGRESS=1 -generic MEM_WORDS=$MW

# clock constraint for a timing estimate
create_clock -name clk -period $PERIOD [get_ports clk]
opt_design -quiet

set tag "hwr_${AY}x${AX}_mw${MW}"
report_utilization     -file util_${tag}.rpt
report_timing_summary  -file timing_${tag}.rpt -max_paths 10

set ncores [expr {$AY*$AX}]
puts "================  mailbox mesh  ${AY}x${AX} = ${ncores} cores, MEM_WORDS=${MW}, [expr {1000.0/$PERIOD}] MHz target  ================"
foreach line [split [report_utilization -return_string] "\n"] {
  if {[regexp {CLB LUTs|CLB Registers|Block RAM Tile|RAMB36|RAMB18|URAM|DSPs} $line]} { puts $line }
}
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths]} {
  puts "worst setup slack: [get_property SLACK [lindex $paths 0]] ns  (positive = meets [expr {1000.0/$PERIOD}] MHz)"
}
puts "per-core (approx): divide the above by ${ncores}"
puts "reports -> util_${tag}.rpt  timing_${tag}.rpt"
