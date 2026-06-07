#!/bin/bash
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
GSM=/usr/local/src/sv2ghdl/yosys/gen_statemachine
"$GSM" "$D/consumer.v" consumer "$D/consumer_sm.c" >/dev/null 2>&1
cd "$D"
cc -O2 golden_raccel.c -o golden_raccel; ./golden_raccel > golden_r.txt
echo "golden: $(tr '\n' ' ' < golden_r.txt)"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_raccel.elf ../m1/start.S mb_raccel.c
riscv64-unknown-elf-objcopy -O binary mb_raccel.elf mb_raccel.bin
hexdump -v -e '1/4 "%08x\n"' mb_raccel.bin > mb_raccel.hex
rm -rf obj_raccel
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_raccel \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_raccel.sv \
  --Mdir obj_raccel -o sim_raccel >/dev/null 2>&1
./obj_raccel/sim_raccel 2>&1 | tee sim_outr.txt | grep -aE 'program words|captured|TIMEOUT' || true
grep -aoE 'RACCEL_OUT [0-9]+' sim_outr.txt | awk '{print $2}' > arrayr.txt
echo "array : $(tr '\n' ' ' < arrayr.txt)"
if [ -s arrayr.txt ] && diff -q <(head -12 golden_r.txt) <(head -12 arrayr.txt) >/dev/null; then
  echo "RACCEL.0 DUT-ON-ARRAY + TB-ON-ARM PASS (== golden)"
else echo "RACCEL.0 FAIL"; fi
