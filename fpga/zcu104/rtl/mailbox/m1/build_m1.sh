#!/bin/bash
# M1: build the C worker -> hex, verilate the loopback SoC sim, run it.
set -e
cd "$(dirname "$0")"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -T ldx.ld -Wl,--gc-sections -o mb_worker.elf start.S mb_worker.c
riscv64-unknown-elf-objcopy -O binary mb_worker.elf mb_worker.bin
hexdump -v -e '1/4 "%08x\n"' mb_worker.bin > mb_worker.hex
rm -rf obj_m1
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_soc_mb \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ldx_soc_mailbox.v \
  /usr/local/src/ldx/fpga/rtl/VexRiscv.v ldx_cfu_stub.v tb_soc_mb.sv \
  --Mdir obj_m1 -o sim_m1
exec ./obj_m1/sim_m1
