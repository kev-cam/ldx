# ARM-side driver for the 8×8 mailbox array (ZCU104)

`mb_host.h` + `mb_run.c` drive the PL array (`mb_array_top`) from the ARM PS over
the AXI4-Lite slave (base `0xA0000000`). Same per-core `.hex` images and packet
format as the Verilator sims, so a sim that passes runs identically on hardware.

## 0. Load the bitstream (once, on the board)
```
# PetaLinux/Ubuntu with fpga_manager + fpgautil:
fpgautil -b system_wrapper.bit                  # (or xmutil loadapp, or convert to .bin)
```
`system_wrapper.bit` is in `../build/zcu104_mb8x8/.../impl_1/`. Confirm the AXI base
the PS assigned (`0xA0000000` here); if different, build with `-DMB_BASE=0x...`.

## 1. Build the driver
```
make                       # native on the board
make CROSS=aarch64-linux-gnu-   # cross from x86
```

## 2. Run
```
sudo ./mb_run <prog.hex> [--drive N | --stream SECS]
```
- **`--drive N`** — correctness: the ARM is the testbench. Injects `x=0..N-1` to core
  (0,0) and reads one egress output per input (lock-step). ARM/AXI-bound, so this
  measures *correctness*, not speed. Use the consumer DUT image
  (`m3c/mb_raccel.hex`): expect outputs `0 6 5 8 7 2 1 4 3 14 …` (== the sim golden).
- **`--stream SECS`** (default) — throughput: the array runs autonomously; the ARM
  drains egress and samples `CYCCNT` to report the array's **simulated-cycles/s**.
  Use a self-driving image that emits to egress.

## 3. Speedup
The array clocks at 200 MHz (timing-closed). `--stream` prints `Mcycles/s` of
*simulated* RTL cycles. Compare against the same design's cycles/s in software
(vvp / nvc / Verilator on x86 or the ARM) → that ratio is the acceleration.
For a fair number, the on-array design should run many cycles per egress message
(so neither the AXI read nor egress backpressure is the bottleneck) — i.e. the DUT
streams out periodic results, not one per cycle.

## Register map (`mb_array_top.v`)
| off | reg | dir | meaning |
|---|---|---|---|
| 0x00 | CTRL | W | [0]=array reset · [1]=cpu_rst_req |
| 0x04 | LOADA | W | program load word address |
| 0x08 | LOADD | W | load word at LOADA into every node; LOADA++ |
| 0x0C | INGRW0 | W | ingress word0 `(y<<16)|(x<<8)|size` |
| 0x10 | INGRD1 | W | inject `{INGRW0,this}` to a core |
| 0x14 | EGR | R | pop one egress word |
| 0x18 | STATUS | R | [0]=egr ne · [1]=quiescent · [2]=ingr busy · [3]=egr full |
| 0x1C | CYCCNT | R | barrier cycle_advance count |

## Notes
- Needs `/dev/mem` (run as root). For a deployed system use a UIO device instead.
- A design must send results to **egress** for the ARM to see them (the `pipe/`
  testcase stores to BRAM — adapt its last stage to `mb_display`/off-array, like
  `m3c/mb_raccel.c`, before running it here).
