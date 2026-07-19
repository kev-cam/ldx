#!/bin/bash
# build_pipe.sh [AY AX PIPE_LEN]  default 4 4 4
set -e
D="$(cd "$(dirname "$0")" && pwd)"; cd "$D"
AY=${1:-4}; AX=${2:-4}; PL=${3:-4}
/usr/local/src/sv2ghdl/yosys/gen_statemachine "$D/stage.v" stage "$D/stage_sm.c" >/dev/null 2>&1
cd "$D"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os -fno-builtin -nostdlib -ffreestanding \
  -DPIPE_LEN=$PL -I../m1 -I. -T ../m1/ldx.ld -Wl,--gc-sections -o mb_pipe.elf ../m1/start.S mb_pipe.c
riscv64-unknown-elf-objcopy -O binary mb_pipe.elf mb_pipe.bin
hexdump -v -e '1/4 "%08x\n"' mb_pipe.bin > mb_pipe.hex
rm -rf obj_pipe
verilator --binary --timing -sv -I.. -Wno-fatal --top-module tb_pipe \
  -GAY=$AY -GAX=$AX -GPIPE_LEN=$PL -GUSE_MESH=1 \
  ../mailbox_pkg.sv ../mb_slot_file.sv ../mb_nif.sv ../mb_router.sv ../mb_mesh.sv ../mb_barrier.sv \
  ../ldx_soc_mailbox.v ../mb_array_soc.v /usr/local/src/ldx/fpga/rtl/VexRiscv.v ../m1/ldx_cfu_stub.v tb_pipe.sv \
  --Mdir obj_pipe -o sim_pipe >/dev/null 2>&1
./obj_pipe/sim_pipe 2>&1 | grep -aiE 'program words|outputs at|PIPE PASS|PIPE FAIL|TIMEOUT'
