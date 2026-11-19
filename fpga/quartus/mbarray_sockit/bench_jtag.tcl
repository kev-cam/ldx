# bench_jtag.tcl — read the SHA compute benchmark (mb_shabench: AAAA marker,
# 100 blocks back-to-back, BBBB|digest-check marker) via the ISSP timestamps.
#   <qbin>/quartus_stp -t bench_jtag.tcl
package require ::quartus::insystem_source_probe
set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -device_name $dev -hardware_name $hw

proc fld {bits hi lo} { set L [string length $bits]; return [string range $bits [expr {$L-1-$hi}] [expr {$L-1-$lo}]] }
proc rd {} { return [read_probe_data -instance_index 0] }

# wait for both markers (egr_cnt == 2)
for {set i 0} {$i < 20000} {incr i} {
  set b [rd]
  if {[expr "0b[fld $b 38 32]"] >= 2} { break }
}
set b [rd]
set cnt     [expr "0b[fld $b 38 32]"]
set head    [format %08x [expr "0b[fld $b 31 0]"]]
set t_first [expr "0b[fld $b 81 50]"]
set t_last  [expr "0b[fld $b 113 82]"]
set dcyc    [expr {$t_last - $t_first}]
puts [format "egr_cnt=%d head=%s (expect aaaa0000)" $cnt $head]
puts [format "t_first=%u t_last=%u  delta=%u cyc" $t_first $t_last $dcyc]
puts [format "cyc/block = %.0f   (ZCU104 URAM: 110796; Verilator 1-cyc model: 55406)" [expr {$dcyc/100.0}]]

# pop both markers to verify the done word carries the digest check bits
set pop_tgl 0
proc pop {} {
  global pop_tgl
  set b [rd]; set w [expr "0b[fld $b 31 0]"]
  set pop_tgl [expr {1-$pop_tgl}]
  write_source_data -instance_index 0 -value [format %09X [expr {$pop_tgl<<32}]] -value_in_hex
  after 20
  return $w
}
set m1 [format %08x [pop]]
set m2 [format %08x [pop]]
puts "markers: $m1 $m2 (expect aaaa0000 bbbb16bf)"
end_insystem_source_probe
