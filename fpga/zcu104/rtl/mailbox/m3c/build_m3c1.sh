#!/bin/bash
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
GSM=/usr/local/src/sv2ghdl/yosys/gen_statemachine
"$GSM" "$D/producer.v" producer "$D/producer_sm.c" >/dev/null 2>&1
"$GSM" "$D/consumer.v" consumer "$D/consumer_sm.c" >/dev/null 2>&1
"$GSM" "$D/top.v"      top      "$D/top_sm.c"      >/dev/null 2>&1
cd "$D"
cc -O2 golden_drv1.c -o golden_drv1; ./golden_drv1 > golden1.txt
echo "golden: $(tr '\n' ' ' < golden1.txt)"
python3 genmap.py m3c1.map > m3c_map.h
echo "--- m3c_map.h ---"; cat m3c_map.h
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_m3c1.elf ../m1/start.S mb_m3c1.c
riscv64-unknown-elf-objcopy -O binary mb_m3c1.elf mb_m3c1.bin
hexdump -v -e '1/4 "%08x\n"' mb_m3c1.bin > mb_m3c1.hex
rm -rf obj_m3c1
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_m3c1 \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_m3c1.sv \
  --Mdir obj_m3c1 -o sim_m3c1 >/dev/null 2>&1
./obj_m3c1/sim_m3c1 2>&1 | tee sim_out1.txt | grep -aE 'program words|captured|TIMEOUT' || true
grep -aoE 'M3C1_DISP [0-9]+' sim_out1.txt | awk '{print $2}' > array1.txt
echo "array : $(tr '\n' ' ' < array1.txt)"
if [ -s array1.txt ] && diff -q <(head -12 golden1.txt) <(head -12 array1.txt) >/dev/null; then
  echo "M3c1 CROSS-CORE-SPLIT PASS (array matches golden)"
else echo "M3c1 FAIL"; fi
