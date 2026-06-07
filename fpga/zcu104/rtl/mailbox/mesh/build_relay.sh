#!/bin/bash
# build_relay.sh [AY AX DESTHEX]   default 4 4 33
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
AY=${1:-4}; AX=${2:-4}; DEST=${3:-33}
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -DDEST_YX=0x${DEST}u -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_relay.elf ../m1/start.S mb_relay.c
riscv64-unknown-elf-objcopy -O binary mb_relay.elf mb_relay.bin
hexdump -v -e '1/4 "%08x\n"' mb_relay.bin > mb_relay.hex
rm -rf obj_relay
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_relay \
  -GAY=$AY -GAX=$AX -GDEST=8\'h${DEST} \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_relay.sv \
  --Mdir obj_relay -o sim_relay >/dev/null 2>&1
./obj_relay/sim_relay 2>&1 | grep -aiE 'program words|dest \(|PASS|FAIL|TIMEOUT'
