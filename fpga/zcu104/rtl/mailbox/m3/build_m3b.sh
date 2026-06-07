#!/bin/bash
set -e
cd "$(dirname "$0")"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -T ../m1/ldx.ld -Wl,--gc-sections -o mb_m3b.elf ../m1/start.S mb_m3b.c
riscv64-unknown-elf-objcopy -O binary mb_m3b.elf mb_m3b.bin
hexdump -v -e '1/4 "%08x\n"' mb_m3b.bin > mb_m3b.hex
rm -rf obj_m3b
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_m3b \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_m3b.sv \
  --Mdir obj_m3b -o sim_m3b
exec ./obj_m3b/sim_m3b
