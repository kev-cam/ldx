# build_8x8.tcl — synthesize, implement, and write the bitstream for the project
# made by create_8x8_project.tcl. Run:  vivado -mode batch -source build_8x8.tcl
set script_dir [file dirname [file normalize [info script]]]
set proj_dir   "$script_dir/build/zcu104_mb8x8"
open_project $proj_dir/zcu104_mb8x8.xpr

reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "## synth_1 FAILED:"; puts [get_property STATUS [get_runs synth_1]]; exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "## impl_1 FAILED:"; puts [get_property STATUS [get_runs impl_1]]; exit 1
}

open_run impl_1
report_utilization    -file $proj_dir/util_impl.rpt
report_timing_summary -file $proj_dir/timing_impl.rpt
puts "## ===== done ====="
puts "## bitstream: $proj_dir/zcu104_mb8x8.runs/impl_1/system_wrapper.bit"
puts "## reports:   $proj_dir/util_impl.rpt  $proj_dir/timing_impl.rpt"
