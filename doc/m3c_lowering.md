# M3c — lowering real designs onto the array by recompiling the --accel C

**Strategy (Kevin's steer): reuse the C that `--accel` already generates, and recompile it for a
particular array core — once you know where that core's inputs and outputs live in the BRAMs.** This
replaces the heavy "retarget NVC's JIT/LLVM to RV32" plan (decision #3 in [m3_lowering.md](m3_lowering.md))
with something that reuses three things already working: the accel C generator, the M3a/M3b event
loop, and the mailbox fabric.

## Why this beats the NVC-JIT path

The Explore of `nvc/src` confirmed the JIT route is expensive: `jit-llvm.c` hardcodes the host triple
(`LLVMGetDefaultTargetTriple`, jit-llvm.c:507), generated code funnels through ~51 runtime "exit"
functions (`jit-exits.c` `__nvc_do_exit`) that assume the host model/`mspace`/scheduler, and it drags
in soft-float + a malloc. Retargeting all that to a tiny RV32 core is weeks of backend work.

The `--accel` C is the opposite: **self-contained, synthesizable logic already lowered to plain C**,
no NVC runtime deps. We fixed and shipped this generator (gen_statemachine/yosys). Recompiling it with
`riscv64-unknown-elf-gcc -march=rv32i` is trivial; the only new glue is binding its boundary signals
to BRAM + mailbox instead of to NVC's signal storage.

## The array is the fixed accelerator — designs load as code, two code paths

The array (RISC cores + mailbox fabric) is the **fixed** FPGA design. We do **not** re-synthesize the
fabric per DUT — that's the slow FPGA build we're avoiding. A design is **compiled to code and loaded
onto the cores**. `--accel`/yosys emits the **state-machine version** of each synthesizable partition,
and *that* is what we compile for the RISC core(s). Every partition takes one of two code paths, both
running as code on a core and coordinating over the same mailbox NIF + barrier (so the mix stays
cycle-accurate):

1. **accel/yosys state-machine C → `riscv32-gcc`** — the main path for synthesizable logic. The
   modified VHDL/--accel flow partitions the design and emits a per-core `sm_eval` state machine with
   its boundary I/O mapped to BRAM/mailbox; compile for RV32, run in the M3a/M3b event loop. (One
   source: the same C also runs in Verilator/x86/ARM for bring-up.)
2. **re-JIT (NVC → RV32)** — *required*, for processes yosys can't synthesize (full TB behavior,
   dynamic/aggregate constructs, system tasks). Heavier (the exit-ABI/`mspace`/soft-float work above),
   used only for that non-synthesizable minority, mostly TB-side.

So "making the FPGA code" = generating these per-core programs (state-machine C + the re-JIT'd
processes) for the fixed core array. The placement map assigns each partition a code path as well as a
location; the mailbox NIF looks the same from either side of any cut.

## What the accel generator emits (grounded in /tmp/*_nvc.c)

Two parts:
- **base** (`#include "<design>.c"`): `state_t` (the registers), `inputs_t`, `outputs_t`, and
  `void sm_eval(state_t *s, const inputs_t *in, outputs_t *o)` — the pure clocked-logic compute.
- **mapped wrapper**: `sm_reg_ptrs[N]` / `sm_reg_widths[N]`, `sm_reg_names[]` (boundary signal names),
  `sm_init_mapped(uint8_t **ptrs, int *widths, int n)` (binds each boundary signal to a pointer),
  `sm_read_nvc()/sm_write_nvc()` (un/pack between the pointer storage and `state_t`),
  `sm_eval_mapped()` = read → `sm_eval` → write.

Example (`cnt32_sm_nvc.c`): one reg `_acc` mapped to `sm_reg_ptrs[0]`; `sm_eval_mapped` increments it.
Example (`flip_flop_fifo_nvc.c`): four regs `WR_PTR/RD_PTR/..` mapped. Storage is **1 byte per bit**
(NVC std_logic) — `v |= (ptr[b]&1)<<b`.

## The mapping on-core: "where the inputs and outputs are in the BRAMs"

Per core, BRAM holds: the program (`sm_eval` + runtime), a **signal region** (the boundary signals),
and the mailbox region. At init the per-core runtime calls `sm_init_mapped(ptrs, widths, n)` with
`ptrs[i] = &BRAM[signal_offset[i]]` — so the generated C reads/writes BRAM directly. A compile-time
**placement map** gives, for every boundary signal: `(home core, BRAM offset, width)` and the
**cross-core edge list** (which other cores consume it). That map *is* "where the I/O is in the BRAMs."

Per-core event loop (the M3a/M3b loop, with compute = `sm_eval_mapped`):
```
each simulated cycle:
  1. drain mailbox: each msg = a remote boundary signal's new value -> write its BRAM input mirror
  2. sm_eval_mapped()            // reads inputs + regs from BRAM, writes regs + outputs to BRAM
  3. for each output consumed on another core -> mb_post(consumer, value)
  4. $display outputs -> off-array (handle + arg words) to the ARM PS host-bridge
  5. CORE_BUSY=0; wait barrier
```
The barrier + in-flight credits already guarantee every cross-core value lands before the next cycle
(M3a/M3b). Cross-core signals get the active/inactive discipline for free: a posted value is deposited
to the consumer's input mirror and read on its *next* `sm_eval` — i.e. value-as-of-cycle-start.

`$display`/`$write`/`$fwrite`/… lower the same way but **off-array to the ARM PS**: the runtime ships
the **args** + a call-site **handle** (size = arg-word count), and the ARM — which holds the format
strings and files keyed by handle — runs the actual `printf`. Only values ship, never the format. On
the board that's egress → PL→PS (AXI/DMA); in sim the TB plays the ARM. The current `mb_display` ships
one arg; the general form ships N arg words behind one handle (see [mailbox.md](mailbox.md)).

## The placement map comes first (the prerequisite artifact)

**Nothing compiles for the array until the map exists**: where every process and signal lands in the
cores and BRAMs. It is two things at once — the **input to per-core codegen** (it tells `sm_init_mapped`
which BRAM offset each boundary signal binds to, and the cross-core edge list tells codegen what to
`mb_post`/receive at the cut) and the **per-node startup config** (`region_base`, `mailbox_base`,
`slot_limit`, `MY_YX`). Schema:

```
partition[]   : { id, substrate: hard | accelC | rejit, core:(y,x) }
signal[]      : { name, home:(y,x), bram_offset, width_bits, fmt: byte-per-bit | packed }
edge[]        : { signal, producer:(y,x), consumers:[(y,x)…], dst slot/region }
core[]        : { bram: program | region_base(signals) | mailbox_base ; slot_limit }
```

For **M3c.0** this is one hand-written line (one core, `_acc` at one offset, no edges). The
**partitioner (M3c.2)** is precisely the tool that *generates* this map automatically from the
elaborated signal graph — min-cut over `rt_nexus_t->outputs → driver proc` (per the NVC Explore).
Define the format now; hand-author it for the early milestones, generate it later. Codegen, the
runtime config, and the FPGA-build wrapper all read from this one map.

## Sub-milestones

- **M3c.0 — one design, one core, accel-C on RV32.** Take `cnt32` (free-running counter): generate
  `sm_eval` via the accel path, recompile for RV32, run it inside the M3a-style loop on a single node
  (no cross-core), bind `_acc` to a BRAM word, `$display` it each cycle, diff against the vvp/nvc
  golden. Proves the accel-C → RV32 → event-loop path end to end.
- **M3c.1 — split one design across 2 cores.** A design with a real net crossing the cut (e.g. a
  producer block on A feeding a consumer block on B). Generate `sm_eval` per partition; route the
  crossing signal over the mailbox using the placement map. **Gap to close:** the generator currently
  maps only registers as boundary signals — extend it to also map the chosen cut's **I/O ports** so a
  net can be a cross-core edge (or pick a cut where the crossing signal is already a register).
- **M3c.2 — partitioner + a real DUT.** A signal-graph min-cut (start hand-partitioned) generates the
  placement map + the per-core state-machine code; lower a real DUT (Yuri `a_plus_b`) across the array.
  The TB and system tasks ride the same fabric (`$display` off-array; the non-synthesizable TB either
  stays hand-lowered as in M3a/M3b or comes through the re-JIT path for constructs synth can't take).

## Open issues / unknowns

- **I/O-port boundary mapping** in gen_statemachine (needed for M3c.1 cross-core nets; today it maps
  registers only).
- **Bit storage**: keep NVC's byte-per-bit (simple, wasteful) or pack to words on-core (the mailbox
  payload is word-oriented — likely pack at the boundary).
- **Partitioner**: min-cut over the nexus/driver graph (`rt_nexus_t->outputs` → driver proc, per the
  Explore) — later; hand-cut first.
- **Multi-driver resolution** across a cut (resolve on one home core).
- **What the synth path can't take** (full TB behavior, dynamic constructs): stays on the M3a/M3b
  hand-lowered runtime, or the NVC-JIT path as a heavier fallback for those processes only.
