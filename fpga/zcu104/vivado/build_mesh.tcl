## build_mesh.tcl — open mesh project, synthesize, implement, write bitstream.
## Run with: vivado -mode batch -source build_mesh.tcl
set script_dir [file dirname [file normalize [info script]]]
set proj_dir   "$script_dir/build/zcu104_ldx_mesh"
open_project $proj_dir/zcu104_ldx_mesh.xpr

reset_run synth_1
launch_runs synth_1 -jobs 6
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "## synth_1 FAILED:"
    puts [get_property STATUS [get_runs synth_1]]
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 6
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "## impl_1 FAILED:"
    puts [get_property STATUS [get_runs impl_1]]
    exit 1
}

puts "## ===== Utilization ====="
report_utilization -file $proj_dir/util.rpt
puts "## Bitstream done"
