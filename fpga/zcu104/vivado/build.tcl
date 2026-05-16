## build.tcl — open milestone-1 project, synthesize, implement, write bitstream.
## Run with: vivado -mode batch -source build.tcl
set script_dir [file dirname [file normalize [info script]]]
set proj_dir   "$script_dir/build/zcu104_ldx_m1"
open_project $proj_dir/zcu104_ldx_m1.xpr

reset_run synth_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "## synth_1 failed:"
    puts [get_property STATUS [get_runs synth_1]]
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "## impl_1 failed:"
    puts [get_property STATUS [get_runs impl_1]]
    exit 1
}

set bit [glob -nocomplain $proj_dir/zcu104_ldx_m1.runs/impl_1/*.bit]
puts "## Bitstream: $bit"
