#!/bin/bash
set -e
cd "$(dirname "$0")"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -T ../m1/ldx.ld -Wl,--gc-sections -o mb_ring.elf ../m1/start.S mb_ring.c
riscv64-unknown-elf-objcopy -O binary mb_ring.elf mb_ring.bin
hexdump -v -e '1/4 "%08x\n"' mb_ring.bin > mb_ring.hex
rm -rf obj_m2
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_array_soc \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v \
  /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_array_soc.sv \
  --Mdir obj_m2 -o sim_m2
exec ./obj_m2/sim_m2
