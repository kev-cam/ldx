#!/bin/bash
set -e
cd "$(dirname "$0")"
rm -rf obj_arr
verilator --binary --timing -sv -I. \
  -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
  --top-module tb_array \
  mailbox_pkg.sv mb_slot_file.sv mb_signal_port.sv mb_nif.sv mb_barrier.sv mb_router.sv \
  mb_core.sv mb_tile.sv mb_array.sv tb/tb_array.sv \
  --Mdir obj_arr -o sim_array
exec ./obj_arr/sim_array
