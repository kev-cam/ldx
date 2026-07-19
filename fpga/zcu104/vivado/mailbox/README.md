# ZCU104 Vivado build — 8×8 mailbox mesh array

Builds the nearest-neighbor mailbox mesh (`mb_array_soc`, 8×8 = 64 VexRiscv cores,
`USE_MESH=1`, 16 KB BRAM/core) for the ZCU104 (xczu7ev-ffvc1156). The PL array is
driven by the ARM PS over AXI4-Lite (`mb_array_top`). Vivado is **not** in the dev
env, so these were authored against the old-mesh scripts and the proven OOC pattern
but only the synth flow is high-confidence; the bitstream flow is scaffolding to
finish on a Vivado machine.

## 1. Utilization + timing (no PS — do this first)

```
vivado -mode batch -source synth_8x8.tcl                 # 8×8, 16 KB/core, 200 MHz
vivado -mode batch -source synth_8x8.tcl -tclargs 8 8 2048 5.0   # 8 KB/core
vivado -mode batch -source synth_8x8.tcl -tclargs 10 10 2048 5.0 # push to 100 cores
```
OOC-synthesizes `mb_array_soc` and prints CLB LUTs / FF / BRAM / DSP and worst
setup slack; full reports in `util_*.rpt` / `timing_*.rpt`. This is the real
check that the config fits. Expected order (from the old 10×10 VexRiscv mesh:
64% LUTs): 8×8 ≈ 40% LUTs, BRAM-bound by MEM_WORDS (4 BRAM36/core × 64 = 256/312).
If BRAM is tight, drop `MEM_WORDS` to 2048 (2 BRAM36/core = 128/312).

## 2. Bitstream (PS-integrated)

```
vivado -mode batch -source create_8x8_project.tcl        # project + PS + AXI BD
vivado -mode batch -source build_8x8.tcl                 # synth + impl + .bit
```
`create_8x8_project.tcl` builds a block design: Zynq UltraScale+ PS (ZCU104 preset)
→ AXI4-Lite → `mb_array_top`. The `apply_bd_automation` calls are version-sensitive
— if rule names differ on your Vivado, adjust. Bitstream lands in
`build/zcu104_mb8x8/.../impl_1/system_wrapper.bit`.

## 3. ARM ↔ PL interface (AXI4-Lite, base = the PS-assigned address)

| off  | reg    | dir | meaning |
|------|--------|-----|---------|
| 0x00 | CTRL   | W   | [0]=array reset (hold) · [1]=cpu_rst_req (hold cores) |
| 0x04 | LOADA  | W   | program load word address |
| 0x08 | LOADD  | W   | load this word at LOADA into every node's BRAM; LOADA++ |
| 0x0C | INGRW0 | W   | host-ingress word0 = `(dst_y<<16)|(dst_x<<8)|size` |
| 0x10 | INGRD1 | W   | inject a 2-beat packet `{INGRW0, this}` to a core |
| 0x14 | EGR    | R   | pop one egress word (DUT output) |
| 0x18 | STATUS | R   | [0]=egr not-empty · [1]=quiescent · [2]=ingr busy · [3]=egr full |
| 0x1C | CYCCNT | R   | barrier cycle_advance count |

Bring-up sketch (the ARM is the testbench):
```c
WR(CTRL, 0b11);                       // hold array + cores in reset
WR(LOADA, 0);                         // load the per-core program (same .hex the sims use)
for (i=0;i<nwords;i++) WR(LOADD, prog[i]);
WR(CTRL, 0b00);                       // release
for (each cycle) {                    // drive the DUT: TB on ARM
    WR(INGRW0, (0<<16)|(0<<8)|1);     // dst (0,0), size 1
    WR(INGRD1, x);                    // inject DUT input x to tile (0,0)
    while (!(RD(STATUS)&1)) ;         // wait for an egress word
    out = RD(EGR);                    // read DUT output
}
```
Same program images (`*.hex`) and packet format as the Verilator sims — so a sim
that passes (e.g. `mesh/`, `pipe/`, `m3c/`) should behave identically on hardware,
just faster.

## Files
- `synth_8x8.tcl` — OOC synth → utilization/timing (high confidence).
- `mb_array_top.v` — PL top: `mb_array_soc` + AXI4-Lite slave (verify the slave).
- `create_8x8_project.tcl` — project + PS + AXI block design (version-sensitive).
- `build_8x8.tcl` — synth + impl + bitstream.
