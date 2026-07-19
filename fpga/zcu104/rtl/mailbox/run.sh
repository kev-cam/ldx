#!/bin/bash
# Build + run the mailbox fabric unit sim (Verilator). Iterate here; FPGA later.
set -e
cd "$(dirname "$0")"
rm -rf obj_sim
verilator --binary --timing -sv -I. \
  -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-UNOPTFLAT -Wno-PINMISSING \
  --top-module tb_mailbox \
  mailbox_pkg.sv mb_slot_file.sv mb_signal_port.sv mb_nif.sv mb_barrier.sv mb_router.sv tb/tb_mailbox.sv \
  --Mdir obj_sim -o sim_mailbox
exec ./obj_sim/sim_mailbox
