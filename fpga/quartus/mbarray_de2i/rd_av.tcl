# rd_av.tcl — read the de2i_av_top ISSP probe (544b) and print disp_count + the
# 16 captured display values as signed decimals. Run on the board:
#   LD_LIBRARY_PATH=<qbin> quartus_stp -t rd_av.tcl
package require ::quartus::insystem_source_probe
set hw [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -device_name $dev -hardware_name $hw
set bits [read_probe_data -instance_index 0]
end_insystem_source_probe
# probe layout (MSB..LSB): disp_count[495:480] log14..log0 (each 32)
set n [string length $bits]
proc fld {bits hi lo} { set L [string length $bits]; return [string range $bits [expr {$L-1-$hi}] [expr {$L-1-$lo}]] }
set dcount  [expr "0b[fld $bits 495 480]"]
puts "disp_count=$dcount"
for {set i 0} {$i < 15} {incr i} {
  set hi [expr {$i*32 + 31}]; set lo [expr {$i*32}]   ;# log0 at [31:0]
  set u [expr "0b[fld $bits $hi $lo]"]
  if {$u >= 2147483648} { set u [expr {$u - 4294967296}] }  ;# signed 32-bit
  puts "log$i = $u"
}
