# ldx on ZCU104 — VexRiscv mesh with AXI4-Lite host bridge

Two milestones land here:

1. **`zcu104_ldx_m1`** — single VexRiscv RV32I + CFU + 4 KB BRAM behind one
   AXI4-Lite slave. Single mailbox register for host-relayed hypercalls.
   The A53 daemon (`sw/ldx_daemon.c`) prints `Hello\n` driven by `sw/hello.c`.

2. **`zcu104_ldx_mesh`** — 5×5 mesh of those cores, point-to-point FIFOs
   on the four mesh ports (N/E/S/W). 20 boundary FIFO pairs route to a
   host bridge (`rtl/ldx_mesh_bridge.v`) so the A53 acts as the outer ring
   of a 7×7 grid. `sw/universal.c` runs on all 25 cores; runtime
   `MY_X / MY_Y` are read from MMIO `0xF0000040`. `sw/mesh_daemon.c`
   loads the same binary into every core, releases reset, polls
   boundary endpoints. wander_call from (1,1) to (5,5) and back ships
   the result westward to the host daemon, which prints `FN_LOG: 42`.

## Resource cost on XCZU7EV (Vivado 2025.2, mesh build)

|              | used   | total   | %    |
| ------------ | ------ | ------- | ---- |
| CLB LUTs     | 95,772 | 230,400 | 41.6 |
| BRAM tiles   |     25 |     312 |  8.0 |
| DSPs         |    100 |   1,728 |  5.8 |

Pl_clk0 = 33.3 MHz. The critical path is the combinational div/mod in
the CFU (`vl_div_iii`, `vl_moddiv_iii`, ~28 ns through 25 instances);
either pipeline those or drop them to take the clock back to ~100 MHz.

## Building

### RV32I firmware

```
make -C sw
```

Produces a `.bin / .dis / .hex` per program plus the aarch64 daemons.
`.hex` files are padded to 1024 words (4 KB BRAM size) with `nop`
fillers so they can be `$readmemh`'d into any node directly.

### Vivado bitstream

```
cd vivado
source /opt/AMD/2025.2/Vivado/settings64.sh
vivado -mode batch -source create_mesh_project.tcl   # creates build/zcu104_ldx_mesh/
vivado -mode batch -source build_mesh.tcl            # synth+impl+bitstream
```

Sources reach into the rest of the repo via relative paths
(`../../rtl/VexRiscv.v`, `../../../simulators/verilator/cfu_vl_*.v`).
The single-core build uses `create_project.tcl` + `build.tcl` instead.

### Sim

```
cd sw && make            # builds *.hex
cp sw/*.hex sim/         # testbenches expect hex files in cwd
cd sim
iverilog -g2012 -o tb_mesh55.vvp tb_mesh55.v \
    ../rtl/{fifo,ldx_soc_mesh,mesh_top}.v \
    ../../rtl/ldx_cfu.v \
    ../../../simulators/verilator/cfu_vl_*.v \
    ../../rtl/VexRiscv.v
vvp tb_mesh55.vvp
```

## On-target run

```
scp vivado/build/zcu104_ldx_mesh/zcu104_ldx_mesh.runs/impl_1/system_wrapper.bit.bin \
    sw/universal.bin sw/mesh_daemon root@zcu104:/tmp/
ssh root@zcu104 '
    cp /tmp/system_wrapper.bit.bin /lib/firmware/ldx_mesh.bit.bin
    echo 0 > /sys/class/fpga_manager/fpga0/flags
    echo ldx_mesh.bit.bin > /sys/class/fpga_manager/fpga0/firmware
    cd /tmp && ./mesh_daemon universal.bin
'
```

Expect `FN_LOG: 42` on stdout once the caller at (1,1) finishes its
8-hop round trip to (5,5).

## Memory map

### Single-core slave (`zcu104_ldx_m1`, 8 KB at PS 0xA0000000)

| offset      | r/w | meaning                                |
| ----------- | --- | -------------------------------------- |
| 0x0000-0x0FFF | rw  | BRAM window (CPU held in reset to load) |
| 0x1F00      | rw  | CTRL  bit0 = cpu_reset                  |
| 0x1F04      | rw  | MBOX_DATA  CPU→PS or PS→CPU             |
| 0x1F08      | r   | MBOX_STATUS  bit0 = pending             |
| 0x1F80      | r   | MAGIC  = `"LDX3"` (0x4C445833)          |

### Mesh slave (`zcu104_ldx_mesh`, 128 KB at PS 0xA0000000)

| offset                       | r/w | meaning                       |
| ---------------------------- | --- | ----------------------------- |
| 0x00000-0x18FFF              | rw  | 25 × 4 KB BRAM windows        |
| 0x19000                      | rw  | CTRL_RESET  bit i = hold core i |
| 0x19100 + ep*0x10            | --- | per-endpoint regs (ep ∈ [0,20)) |
|   +0x0                       | w   | PUSH_DATA (enqueue to softcore) |
|   +0x4                       | r   | PUSH_STATUS  bit0 = full        |
|   +0x8                       | r   | POP_DATA (read drains FIFO)     |
|   +0xC                       | r   | POP_STATUS  bit0 = empty        |
| 0x19F00                      | r   | MAGIC = `"LDX4"` (0x4C445834)   |

### Message header (32-bit, multi-word messages start with one of these)

| bits   | field    |
| ------ | -------- |
| [31:29] | dest_x   |
| [28:26] | dest_y   |
| [25:23] | src_x    |
| [22:20] | src_y    |
| [19:18] | op (0=fire, 1=call, 2=return) |
| [17:10] | fn_id    |
| [9:7]   | argc     |
| [6:0]   | ret_tag  |

Followed by `argc` arg words.

## Per-core mesh MMIO (CPU's view inside any softcore)

| address (dir d ∈ {0=N, 1=E, 2=S, 3=W}) | r/w | meaning                |
| --------------------------------------- | --- | ---------------------- |
| 0xF0000040                              | r   | `{26'd0, MY_Y, MY_X}`   |
| 0xF0000100 + 0x10*d + 0x0               | w   | PUSH_DATA toward dir d  |
| 0xF0000100 + 0x10*d + 0x4               | r   | PUSH_STATUS  bit0 = full |
| 0xF0000100 + 0x10*d + 0x8               | r   | POP_DATA from dir d (also dequeues) |
| 0xF0000100 + 0x10*d + 0xC               | r   | POP_STATUS  bit0 = empty |
