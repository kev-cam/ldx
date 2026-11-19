# sha_jtag.tcl — TB-on-host over JTAG: drive SHA-256("abc") through the ISSP
# bridge in sockit_jtag_top and check the digest against the FIPS vector.
#   <qbin>/quartus_stp -t sha_jtag.tcl
package require ::quartus::insystem_source_probe
set hw  [lindex [get_hardware_names] 0]
set dev [lindex [get_device_names -hardware_name $hw] 0]
start_insystem_source_probe -device_name $dev -hardware_name $hw

proc fld {bits hi lo} { set L [string length $bits]; return [string range $bits [expr {$L-1-$hi}] [expr {$L-1-$lo}]] }
proc rd_probe {} { return [read_probe_data -instance_index 0] }
proc p_head {b}   { expr "0b[fld $b 31 0]" }
proc p_cnt  {b}   { expr "0b[fld $b 38 32]" }
proc p_ack  {b}   { expr "0b[fld $b 46 39]" }
proc p_st   {b}   { expr "0b[fld $b 49 48]" }

set in_tgl 0
set pop_tgl 0
proc wr_src {word} {
  global in_tgl pop_tgl
  set v [expr {($in_tgl<<33) | ($pop_tgl<<32) | ($word & 0xFFFFFFFF)}]
  write_source_data -instance_index 0 -value [format %09X $v] -value_in_hex
}
proc send_word {word} {
  global in_tgl
  set ack0 [p_ack [rd_probe]]
  set in_tgl [expr {1-$in_tgl}]
  wr_src $word
  for {set i 0} {$i < 1000} {incr i} {
    if {[p_ack [rd_probe]] != $ack0} { return }
  }
  error "ingress ack timeout (ack=$ack0)"
}
proc pop_word {} {
  global pop_tgl
  for {set i 0} {$i < 20000} {incr i} {
    set b [rd_probe]
    if {[p_cnt $b] > 0} {
      set w [p_head $b]
      set pop_tgl [expr {1-$pop_tgl}]
      wr_src 0
      return $w
    }
  }
  error "egress timeout"
}

set b [rd_probe]
puts [format "harness: st=%d loaded, egr_cnt=%d" [p_st $b] [p_cnt $b]]

# SHA-256("abc") single padded block, big-endian words
set blk [list 0x61626380 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0x00000018]
foreach w $blk { send_word $w }
puts "sent 16 block words"

set digest {}
for {set i 0} {$i < 8} {incr i} { lappend digest [format %08x [pop_word]] }
puts "digest = $digest"

set golden {ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad}
if {$digest eq $golden} { puts "SHA-256 ON SOCKIT: PASS" } else { puts "MISMATCH vs $golden" }
end_insystem_source_probe
