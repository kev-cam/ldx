#!/bin/bash
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
SHA=/usr/local/src/ldx/examples/verilator-bench/sha256
/usr/local/src/sv2ghdl/yosys/gen_statemachine "$SHA/Sha256.v" Sha256 "$D/sha_sm.c" >/dev/null 2>&1
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_sha.elf ../m1/start.S mb_sha.c 2>&1 | grep -aiE 'error|undefined' | head || true
riscv64-unknown-elf-objcopy -O binary mb_sha.elf mb_sha.bin
echo "program bytes: $(wc -c < mb_sha.bin)"
hexdump -v -e '1/4 "%08x\n"' mb_sha.bin > mb_sha.hex
rm -rf obj_sha
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_sha \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_mesh.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_sha.sv \
  --Mdir obj_sha -o sim_sha >/dev/null 2>&1
NW=$(wc -l < mb_sha.hex)
./obj_sha/sim_sha +NW=$NW 2>&1 | grep -aiE 'program words|digest:|PASS|FAIL|TIMEOUT|DBG'
