# M3 — whole simulation on the array (event-processing personality + lowering)

The endgame: replace the M2 ring worker with the **real event-processing personality**, and lower an
actual HDL design (DUT + TB + system tasks) onto the array as per-core programs. No host-side TB, no
nvc-runs-DUT / can't-drive-TB federation split — one process graph over the mailbox. Builds on
[mailbox.md](mailbox.md) and [rv32_core.md](rv32_core.md).

## The personality (per-core event loop)

Each core runs a discrete-event simulator of its partition. State = its **signals** in BRAM, as an
**active/inactive double buffer** (`region_base` + the `op_bit ⊕ cycle_parity` we built). Processes =
code blocks with sensitivity lists. Per simulated (clock) cycle:

```
1. eval: run every process whose sensitivity fired (clocked procs on the edge).
     reads  -> loads from the ACTIVE region
     writes -> stores to the INACTIVE region (next-cycle / NBA) via mb_signal_port
     a write to a signal consumed on another core -> ALSO mb_post() to that core
2. drain: for each ready mailbox slot — a remote signal change —
     deposit it (active for comb, inactive for registered) + mark local sensitive procs
3. iterate 1<->2 until no local events and no incoming  = local quiescence
4. CORE_BUSY=0; wait for the barrier (CYCLE_CNT change)
5. advance: cycle_parity flips (inactive becomes active); re-eval triggered procs next cycle
```

The barrier + in-flight credits guarantee every cross-core message lands before the cycle advances
(M2 already proved that machinery). The fabric stays pure routing+addressing; this loop *is* the
personality.

## Signal model on-core

- A signal = a word (or a few) in the banked region; `region_base + offset`, active/inactive by the
  cycle parity. **Registered/NBA** writes go to inactive (visible next cycle after the flip);
  **combinational** writes go to active and re-trigger sensitive procs this cycle (delta cycles).
- **Cross-partition edges**: a signal produced on core A and read on core B is, at compile time, a
  mailbox post A→B. The partitioner assigns each signal a home core; consumers on other cores get a
  post; the consumer's drain deposits it into its local mirror of that signal.
- **Fan-out**: a signal read on k other cores → k posts (or a tree); the dedicated-BRAM bulk path is
  the optimization for hot high-fanout edges.

## System tasks (already designed in mailbox.md)

`$display(fmt,args)` → off-array message of the **args only** to the host-bridge (it holds the fmt,
keyed by the call-site handle); `$finish/$stop` → control packet; `$urandom` → local per-thread RNG;
`$random` → global-stream policy. In sim, the **TB plays the host-bridge**: it captures `egr_*`
packets, looks up the format by handle, prints (reordered by source-timestamp).

## Lowering pipeline

```
HDL (VHDL / SV-via-sv2ghdl)
  -> NVC front-end: elaborate, processes + sensitivity + signal graph
  -> PARTITION the signal graph across N cores (min-cut)            [Mylex / hand for M3a]
  -> per core: process code + signal map (home/mirror) + the cross-core post list
  -> CODE-GEN: NVC LLVM backend retargeted to RV32  (the big lift)  [hand-lowered for M3a]
       runtime swaps: signal-assign->deposit, wait->dispatch, $display->off-array
  -> per-core ELF -> hex -> load into each node BRAM; emit slot_limit/region_base/op tables
```

## Sub-milestones

- **M3a — hand-lowered, clocked-only, 2 cores.** A tiny synchronous design, no combinational
  feedback (avoids delta cycles for the first pass): core A = an N-bit counter (`count<=count+1`);
  core B samples `count` (posted from A each cycle) and `$display`s it. Hand-write the event-loop
  kernel + the two processes in C. Proves: the kernel skeleton, **active/inactive banking actually
  used** (region_base + parity), a real cross-core signal edge over the mailbox, and `$display` →
  egress → TB host-bridge. Check the printed `count` sequence against a reference.
- **M3b — combinational + delta cycles.** Add comb signals and same-cycle re-trigger; a 3–4 process
  design with a comb path crossing a core boundary. Still hand-lowered.
- **M3c — NVC-lowered.** Wire the NVC front-end → partition → RV32 codegen + the mailbox runtime;
  lower a small real design automatically. Then scale toward a real DUT (e.g., the Yuri `a_plus_b`,
  or a small core), partitioned across the array — the headline "whole sim on the array."

## Decisions to confirm

1. **M3a first design**: counter+display (above), or a 2-core ping (A toggles, B inverts+returns)?
2. **Hand-lower M3a/M3b before any NVC work** (recommended — proves the runtime/model cheaply), then
   tackle the NVC→RV32 retarget at M3c?
3. **Codegen for M3c**: retarget NVC's **LLVM** backend to RV32 (doc's plan), or have NVC/Mylex emit
   **C per core** compiled with `riscv64-gcc` (simpler, slower path to first results)?
4. **Delta cycles**: assume clocked-only designs for M3a/M3b (no comb feedback), or build the
   delta-settling loop from the start?
5. **Host-bridge in sim**: TB-side `$display` capture/format by handle — acceptable for M3, with the
   real PCIe/DMA serializer deferred?
