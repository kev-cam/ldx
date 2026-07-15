# rpt_paths.tcl — dump the worst setup paths of a compiled revision.
#   quartus_sta -t rpt_paths.tcl <revision>
set rev [lindex $quartus(args) 0]
project_open $rev -revision $rev
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 3 -detail summary -file ${rev}_paths.txt
delete_timing_netlist
project_close
