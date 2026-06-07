#!/bin/bash
set -e
cd "$(dirname "$0")"
# 1. golden — native run of the same accel sm_eval
cc -O2 golden_drv.c -o golden_drv
./golden_drv > golden.txt
echo "golden: $(tr '\n' ' ' < golden.txt)"
# 2. placement map -> per-core header (codegen)
python3 genmap.py cnt32.map > m3c0_map.h
echo "--- m3c0_map.h ---"; cat m3c0_map.h
# 3. compile the per-core program for the RISC core
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_m3c0.elf ../m1/start.S mb_m3c0.c
riscv64-unknown-elf-objcopy -O binary mb_m3c0.elf mb_m3c0.bin
hexdump -v -e '1/4 "%08x\n"' mb_m3c0.bin > mb_m3c0.hex
# 4. verilate + run the 1-core array
rm -rf obj_m3c0
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_m3c0 \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_m3c0.sv \
  --Mdir obj_m3c0 -o sim_m3c0 >/dev/null 2>&1
./obj_m3c0/sim_m3c0 2>&1 | tee sim_out.txt | grep -aE 'program words|captured|TIMEOUT' || true
# 5. diff array output vs golden
grep -aoE 'M3C0_DISP [0-9]+' sim_out.txt | awk '{print $2}' > array.txt
echo "array : $(tr '\n' ' ' < array.txt)"
if [ -s array.txt ] && diff -q <(head -12 golden.txt) <(head -12 array.txt) >/dev/null; then
  echo "M3c0 ACCEL-C-ON-ARRAY PASS (array matches golden)"
else
  echo "M3c0 FAIL"
fi
