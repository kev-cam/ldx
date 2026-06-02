# Mailbox

A communication fabric for FPGA core arrays running event-driven HDL simulation, generalizing to any accelerator workload that benefits from variable-length, address-routed message passing with immediate and deferred dispatch semantics. Designed around the Wandering Threads dispatch model — work follows data, the trigger bit fires the consumer, and the data lives where the consumer reads.

## Overview

Each core in the array carries a small slot file of message buffers, allocated dynamically from a free mask and consumed in the order ready bits are raised. Each slot holds a destination address, an op byte, and a variable-length payload. Slot dispatch maps directly onto Verilog scheduling regions: an `immediate` bit selects between writing to the active or shadow bank of the consumer's signal BRAM; a `trigger` bit selects between waking the consumer's eval and silently depositing. An `off_array` bit (the sign bit of word 0) virtualizes the destination, so `$display` to the host or a cross-chiplet message uses the same packet format as a local signal update.

Together with the per-edge dual-port BRAM signal store, the mailbox replaces nearest-neighbor mesh routing with a flat 16-bit destination namespace, dissolving the geographic partitioning constraint that limits Wormhole and SpiNNaker class architectures. RTL placement becomes a min-cut on the signal graph rather than a 2D-mesh embedding. Long-haul messages cost more cycles than short ones, but no cut is forbidden.

## Topology

The array does not implement a generic NoC. The signal graph is partitioned at compile time and the fabric provides two cooperating paths:

- **Mailbox slot file** (per core): variable-length messages, immediate or deferred dispatch, op-encoded routing. Event-driven path.
- **Dedicated dual-port BRAM mailboxes** (per high-bandwidth producer-consumer edge): bulk delta updates, header-less, single-cycle writes via port B. Clocked path.

Both share the consumer's signal BRAM. The dedicated-BRAM path carries no header because the producer knows the consumer's signal-table layout at compile time; the slot file carries op-encoded routing for everything else, including all cross-cluster and host traffic.

## Slot file

Default: 8 slots per core, 4 words × 32 bits per slot = 128 bytes per file. The entire slot file lives in distributed LUTRAM — no BRAM36 spent on slot storage. A 64-core cluster spends ~8 KB total, well under 1% of fabric.

8 is a deliberate choice: three-bit slot IDs, 8-bit masks, `ctz` works without width handling on any RV32 variant. `SLOT_COUNT_MAX` stays a synthesis parameter; hot cores (clock distribution, reset trees, top-level test buses) can be built with 16 by flipping one parameter for that core class.

A runtime `slot_limit` CSR caps the live slot count per core to `1..SLOT_COUNT_MAX`:

```
slot_limit  [3:0]                  — programmable per core
slot_mask   = (1 << slot_limit) - 1
```

The allocator pick is `ctz(free_mask & slot_mask)`. Bits beyond the limit are held at zero in both masks, so software sees a narrower file naturally. The compiler emits the per-core `slot_limit` from the partitioned graph: leaf nodes with rare fan-in get 2, hubs get 7 or 8.

## Slot layout

Variable length. Word 0 is the header; words 1..size_words are payload, op-defined.

**Word 0:**

```
[31]     off_array     — sign bit, single-cycle bltz dispatch
[30]     addr_mode     — 0: absolute BRAM offset; 1: bank-relative (XOR bank_id)
[29:24]  op[5:0]       — bank_sel, trigger, wide, op_type[2:0]
[23:16]  dst_y         — on-array; or upper byte of off-array handle
[15:8]   dst_x         — on-array; or lower byte of off-array handle
[7:0]    size_words    — count of following words (0..SLOT_WORDS-1)
```

The placements are load-bearing: `off_array` at [31] for `bltz`, `addr_mode` at [30] so a single `srli 30` peels both routing-mode bits into one register, size at [7:0] for `andi 0xFF`. These three positions are the fabric's commitment; op[5:0] is target-defined and can be re-allocated per accelerator personality.

**Op[5:0] semantics** for the logic-simulator personality:

```
[5]    bank_sel      — when addr_mode=1: live (1) or next (0) bank
[4]    trigger       — wake consumer eval; else silent deposit
[3]    wide          — payload is a pointer into shared scratchpad
[2:0]  op_type       — 8 codes, personality-defined (delta, event, ack, ckpt, ...)
```

For off-array packets (off_array=1), op[5:0] is a target-specific dispatch code for the egress consumer — host, cross-cluster gateway, DPI shim. The on-array fabric doesn't decode it; the NIF routes the whole packet to the egress without further inspection.

The `(addr_mode, bank_sel, trigger)` triple encodes Verilog scheduling regions:

- `(1, 1, 1)` active region — drop live value, wake eval, propagate.
- `(1, 1, 0)` inactive region — force live value without eval (testbench drives, X-injection).
- `(1, 0, 0)` NBA region — deposit for next cycle, no wake.
- `(1, 0, 1)` reserved, traps.
- `(0, *, *)` non-banked write — config load, LUT update, scratchpad write, debug capture.

Address decode at the BRAM port: upper bits of `dst_slot` (in the payload) pick which BRAM in the consumer's local BRAM array, lower bits are the offset within. When `addr_mode=1`, the bank-select bit of the offset XORs with `bank_id` at the port. When `addr_mode=0`, the offset is used directly. Non-banked BRAMs (LUTs, config, scratchpad) have no bank-select bit, so `addr_mode=1` to one of them is harmless — the XOR target doesn't exist.

**Representative payload formats:**

```
size=0   op-only:     barrier_ack, wake, bank_flip_req, free_slot, heartbeat
size=1   logic delta: word 1 = [31:16] value, [15:0] dst_slot
size=1   event post:  word 1 = [31:16] trigger_id, [15:0] dst_slot
size=2   wide value:  word 1 = (dst_slot, src_id), word 2 = value
size=k   vector:      word 1 = (dst_slot_base, stride), words 2..k+1 = vector
```

The NIF writes words 1..size_words first, commits word 0 last, raises the ready bit one cycle after commit. The slot is atomically visible at the ready-bit flip — the consumer never sees a half-written slot.

For oversize messages, `op.wide=1` reinterprets the payload as a pointer into a shared scratchpad region. Size `SLOT_WORDS` for p99 and let `wide` handle the tail.

## Masks

Two CSRs per core (only the low `slot_limit` bits live):

- `free_mask`: 1 = slot is empty
- `ready_mask`: 1 = slot holds an incoming message awaiting consumer dispatch

Three encoded states per slot:

- **FREE**: free=1, ready=0
- **POSTED-TO-ME**: free=0, ready=1
- **IN-FLIGHT-OUT or BUSY-PROCESSING**: free=0, ready=0

The middle state covers both directions; only one of "I'm sending this" or "I'm processing this" can hold per slot at a time, so they share the encoding without ambiguity.

## Consumer dispatch

Five instructions classify a packet completely:

```asm
loop:
  csrr   t0, ready_mask
  beqz   t0, idle
  ctz    t1, t0                    # first ready slot id
  lw     t2, 0(slot_base + t1*16)  # word 0
  bltz   t2, off_array_handler     # off_array == sign bit
  andi   t3, t2, 0xFF              # size_words
  srli   t4, t2, 24                # op[6:0] in low 7 bits (addr_mode at bit 6)
  andi   t5, t4, 0x07              # op_type → jump table (3 bits, 8 codes)
  # ... dispatch on op_type, read words 1..size_words as needed
  csrrc  x0, ready_mask, 1 << t1
  csrrs  x0, free_mask,  1 << t1
  j      loop
idle:
  wfi                              # NIF raises ready_mask → wake
  j      loop
```

No decode dependency chain — `bltz`, size, op_type all peel out independently. A core whose `ready_mask` drains to zero issues `wfi` and consumes zero clocks until the NIF raises ready, so idle phases cost nothing in dynamic power.

## Producer send

A core finds a free slot via `ctz(free_mask)`, writes the payload (words 1..size_words first), commits word 0 through a CSR-mapped window, and pulls a `send` doorbell with the slot id. The NIF ships the slot (gated by `off_array`) and on delivery-ack sets the slot's `free_mask` bit back to 1. Outgoing slots never touch `ready_mask`.

A short per-destination output FIFO (4–8 deep) on each producer absorbs bursts so one full destination doesn't stall the producer's other links.

## Dispatch by addressing mode

The `addr_mode` bit selects how `dst_slot` is delivered to the BRAM port:

```
addr_mode == 0:  absolute BRAM offset, no translation
                 writes to non-banked regions: config, LUTs, scratchpad, debug
addr_mode == 1:  bank-relative offset, bank-select bit XOR bank_id
                 bank_sel == 1: live bank  (active values)
                 bank_sel == 0: next bank  (shadow / NBA region)
```

`(addr_mode=1, bank_sel=1, trigger=1)` is the zero-delay propagation path: write live, wake the consumer. `(addr_mode=1, bank_sel=0)` is the NBA path: invisible until the global barrier flips banks. `addr_mode=0` bypasses the bank machinery entirely, which is how the wide-payload scratchpad, configuration regions, and any consumer-local memory outside the cycle-swap participate in the same packet format.

## Quiescence and barrier

"Cannot advance to the next cycle while any work is pending." Three conditions, all must be zero:

```
any_busy   = OR over cores  of (state != WFI || ready_mask != 0)
in_flight  = sum over network of (msgs sent − msgs delivered)
nif_busy   = OR over NIFs   of (tvalid asserted on any link)
quiescent  = !any_busy && (in_flight == 0) && !nif_busy
```

Hold `quiescent` high for one barrier-tree depth (~log N cycles) to absorb the last in-flight settling, then issue `bank_flip`. Banks swap, deferred values become live, sensitivity lists re-evaluate, cores whose conditions now match get woken via incoming ready bits, the next cycle starts.

The barrier itself is an AND-tree across all cores' `done` flags terminating at a coordinator. On an 8×8 array the tree is 6 deep — under one clock at 200 MHz even after place-and-route.

## Off-array routing

When `op.off_array == 1`, `(dst_y, dst_x)` becomes a 16-bit destination handle into a side channel — PCIe queue id, AURORA endpoint, OAE link descriptor, host doorbell, DPI function handle. The NIF compares `(x,y)` against its on-array address range; out-of-range OR `off_array=1` routes to the egress NIF.

This single bit covers the full Verilog monitor and inactive-region family:

- `$display`, `$write`, `$strobe`, `$monitor`, `$fwrite` — file handle in `(x,y)`
- `$finish`, `$stop` — control packets, op_type=control
- `$random` / `$urandom` — request-response pairs
- `$fatal` / `$error` / `$warning` — severity in op_type
- DPI calls — C function handle in `(x,y)`
- Functional coverage events; SVA assertion fires

Multicycle egress is fine because these defer to the monitor region at end of timestep anyway. The host-side serializer reorders by source-timestamp before printing — a few hundred lines of DMA-fed logic over PCIe on ZCU104.

## Backpressure

When `free_mask & slot_mask == 0`, the local NIF holds AXI-Stream tready low. Producers feel it via their own tvalid stuck. A watchdog on tready-held-low > N cycles flags potential deadlock to the coordinator. Real deadlocks here are almost always a partitioning bug, not transient congestion.

## Boot

At reset, `slot_limit = SLOT_COUNT_MAX` so all slots are visible. The first packets the coordinator sends are config packets that program each core's `slot_limit` to its workload value. No slot reservation, no chicken-and-egg, just a default-wide initial state that narrows once the personality loads. The compiler emits the per-core `slot_limit` table as part of the boot image.

## Sizing on ZCU104

XCZU7EV: 312 BRAM36, 96 URAM288.

- **Slot files**: distributed LUTRAM, no BRAM cost.
- **Dedicated per-edge BRAM mailboxes**: 1 BRAM36 per cut edge — 17-core fully-connected mesh or 60+-core sparse mesh at 4–8-neighbor fan-out.
- **High-fanout consumers**: 1 URAM288 absorbs 32 producers × 256 slots each.
- Memory is not the constraint; port-B fan-in past ~8 producers is, and gets arbitrated through AXI-Stream FIFOs at that point.

## Configurations

The mailbox file is a synthesis-time parameterized structure `(N_SLOTS, SLOT_WORDS, WORD_WIDTH)`. Three sensible tunings:

- **Logic simulator default**: 8 × 4 × 32 = 128 B per file. Distributed RAM.
- **RTL co-sim with bus traffic**: 16 × 8 × 64 = 1 KB per file. One BRAM36 covers it.
- **Control-plane only**: 64 × 1 × 32 = 256 B per file. Op-only event signaling.

The runtime `slot_limit` narrows within the synthesized maximum without rebuilding.

## Integration

- **NVC**: LLVM backend retargets to RV32; runtime library swaps for mailbox primitives. Signal assignment → mailbox post, wait → slot dispatch, `$display` → off-array.
- **pp**: Verilog front-end desugars to the same IR, same mailbox primitives.
- **Mylex**: emits ONNX-graph partitions, per-core `slot_limit`, op_type tables, consumer dispatch code.
- **ldx**: federates the cross-language and cross-cluster boundaries — same model as the existing NVC/Xyce federation, the mailbox primitives become first-class interposable symbols via `dlreplace`/`dlreplaceq`.
- **OAE**: off-cluster transport for `off_array=1` packets, mapped through the existing protocol RTL generation.

## Open

- Physical placement of the slot file — LUTRAM in core vs dedicated dual-ported BRAM36 next to core. Default LUTRAM; promote only if NIF/core arbitration shows up in timing.
- Egress NIF width for verification workloads with heavy logging or fine-grained coverage. Provision for worst-case streaming, not average sim.
- Reorder buffer depth on the host-side serializer for off-array event ordering across cores.
- Whether `wide` payload pointers are absolute or core-local into the shared scratchpad region.
