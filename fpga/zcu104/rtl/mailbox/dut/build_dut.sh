#!/bin/bash
# build_dut.sh [AY AX EGR_PERIOD]   default 4 4 16
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
AY=${1:-4}; AX=${2:-4}; EP=${3:-16}
/usr/local/src/sv2ghdl/yosys/gen_statemachine "$D/stage.v" stage "$D/stage_sm.c" >/dev/null 2>&1
cc -O2 -DEGR_PERIOD=$EP golden_dut.c -o golden_dut; ./golden_dut > golden_d.txt
echo "golden: $(tr '\n' ' ' < golden_d.txt)"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -O2 -fno-builtin -nostdlib -ffreestanding \
  -DEGR_PERIOD=${EP}u -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_dut.elf ../m1/start.S mb_dut.c
riscv64-unknown-elf-objcopy -O binary mb_dut.elf mb_dut.bin
hexdump -v -e '1/4 "%08x\n"' mb_dut.bin > mb_dut.hex
rm -rf obj_dut
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_dut -GAY=$AY -GAX=$AX -GUSE_MESH=1 \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_mesh.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_dut.sv \
  --Mdir obj_dut -o sim_dut >/dev/null 2>&1
./obj_dut/sim_dut 2>&1 | tee sim_outd.txt | grep -aE 'program words|captured' || true
grep -aoE 'EGR [0-9]+ = [0-9]+' sim_outd.txt | awk '{print $4}' > arrayd.txt
echo "array : $(tr '\n' ' ' < arrayd.txt)"
if [ -s arrayd.txt ] && diff -q <(head -12 golden_d.txt) <(head -12 arrayd.txt) >/dev/null; then
  echo "DUT SELF-DRIVE PASS (periodic egress == golden)"
else echo "DUT FAIL"; fi
