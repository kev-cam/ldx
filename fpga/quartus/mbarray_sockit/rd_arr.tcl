# rd_arr.tcl — read the de2i_arr_top ISSP probe (147b, instance "ARR") and print
# the run state.  Layout (MSB..LSB): {st[1:0], donecyc[31:0], cyc[31:0],
# quiescent, egr_cnt[15:0], elog1[31:0], elog0[31:0]}.
#   <qbin>/quartus_stp -t rd_arr.tcl
package require ::quartus::insystem_source_probe
set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -device_name $dev -hardware_name $hw
set bits [read_probe_data -instance_index 0]
end_insystem_source_probe
proc fld {bits hi lo} { set L [string length $bits]; return [string range $bits [expr {$L-1-$hi}] [expr {$L-1-$lo}]] }
proc s32 {u} { if {$u >= 2147483648} { return [expr {$u - 4294967296}] }; return $u }
set elog0   [expr "0b[fld $bits  31   0]"]
set elog1   [expr "0b[fld $bits  63  32]"]
set egrcnt  [expr "0b[fld $bits  79  64]"]
set quiesc  [expr "0b[fld $bits  80  80]"]
set cyc     [expr "0b[fld $bits 112  81]"]
set donecyc [expr "0b[fld $bits 144 113]"]
set st      [expr "0b[fld $bits 146 145]"]
puts "st=$st quiescent=$quiesc cyc=$cyc donecyc=$donecyc"
puts "egr_cnt=$egrcnt elog0=[s32 $elog0] elog1=[s32 $elog1]"
