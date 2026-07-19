#!/bin/bash
# Multi-block SHA256 on the array: gen the accel-C from Sha256mb.v, compile the
# worker for one RISC core, verilate the 1x1 mesh + TB-on-ARM, run the 2-block vector.
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
/usr/local/src/sv2ghdl/yosys/gen_statemachine "$D/Sha256mb.v" Sha256mb "$D/shamb_sm.c" >/dev/null 2>&1
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_shamb.elf ../m1/start.S mb_shamb.c 2>&1 | grep -aiE 'error|undefined' | head || true
riscv64-unknown-elf-objcopy -O binary mb_shamb.elf mb_shamb.bin
echo "program bytes: $(wc -c < mb_shamb.bin)"
hexdump -v -e '1/4 "%08x\n"' mb_shamb.bin > mb_shamb.hex
rm -rf obj_shamb
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_shamb \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_mesh.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_shamb.sv \
  --Mdir obj_shamb -o sim_shamb >/dev/null 2>&1
NW=$(wc -l < mb_shamb.hex)
./obj_shamb/sim_shamb +NW=$NW 2>&1 | grep -aiE 'program words|digest:|PASS|FAIL|TIMEOUT'
