# Mailbox

A communication fabric for FPGA core arrays running event-driven HDL simulation, generalizing to any accelerator that benefits from variable-length, address-routed message passing. Built on the Wandering Threads model: work follows data — a message lands where the consumer reads it, and the ready bit fires the consumer.

## Model

Each core carries a **slot file** of message buffers plus a banked **signal BRAM**. A producer writes a slot; the NIF routes it to the destination core's slot file and raises a ready bit; the consumer drains ready slots in bitmap order. A flat **16-bit `(dst_y, dst_x)` namespace** replaces nearest-neighbor mesh routing — placement becomes a min-cut on the signal graph, not a 2-D embedding. Long-haul messages cost more cycles than short ones; no cut is forbidden. This dissolves the geographic partitioning constraint of Wormhole/SpiNNaker-class fabrics.

The fabric is **pure routing + addressing**. All Verilog scheduling-region semantics (active/inactive, wake) live in a **target-specific op-code** decoded by the personality — the fabric never interprets them.

## Two paths

- **Slot file** (per core): variable-length, op-routed messages. Event-driven. Carries everything irregular — cross-cluster, host, control.
- **Dedicated dual-port BRAM** (per high-bandwidth producer→consumer edge): header-less bulk deltas, single-cycle port-B writes. Clocked. The producer knows the consumer's signal-table layout at compile time, so no header is needed.

Both deposit into the consumer's banked signal BRAM.

## Slots and masks

**Max 32 slots per core** — that's the point: free / ready / allocate are single-instruction bitmap ops on one 32-bit word (`ctz`, `and`, `popcount`) with no width handling on any RV32. A core need not use all 32; `slot_limit` caps the live count. The slots live in a node BRAM wherever a per-node **`mailbox_base` register** points — the compiler places the slot region in whatever block fits (paired with `region_base` for the signal region), so nothing is pinned to a fixed offset. The NIF deposits incoming messages at `mailbox_base + slot*stride`; the processor reads them with ordinary loads. The mailbox is the **long-reach add-on**: where the existing nearest-neighbor mesh reached only N/E/S/W, the mailbox reaches any node via the flat namespace. The free/ready bitmaps are the only separate (register) state; BRAM is plentiful, so the **default slot count is generous**.

Two 32-bit CSRs per core (only the low `slot_limit` bits are live):

- `free_mask`  — 1 = slot empty
- `ready_mask` — 1 = slot holds an incoming message awaiting dispatch

Three states per slot: **FREE** (free=1, ready=0), **POSTED** (free=0, ready=1), **BUSY** (free=0, ready=0 — in-flight-out *or* being processed; only one holds at a time, so they share the encoding).

`slot_limit` (CSR) caps to `1..32`; `slot_mask` = the low `slot_limit` bits, the rest held at zero so software sees a narrower file naturally. Allocator pick = `ctz(free_mask & slot_mask)`. The compiler emits per-core `slot_limit` from the partitioned graph — rare-fan-in leaves get 2, hubs up to 32.

## Slot layout

Variable length. **Word 0 is the fabric header; words 1..size are op-defined payload.**

```
Word 0:
  [31]     off_array   — sign bit, single-cycle bltz dispatch
  [30]     addr_mode   — 0: absolute BRAM offset; 1: banked region (region_base reg)
  [29:24]  op          — TARGET-SPECIFIC; the fabric never decodes it, except to
                         route off-array packets whole to egress
  [23:16]  dst_y       — on-array; or upper byte of off-array handle
  [15:8]   dst_x       — on-array; or lower byte of off-array handle
  [7:0]    size_words  — count of following words (0..SLOT_WORDS-1)
```

Load-bearing placements: `off_array` at [31] (`bltz`), `addr_mode` at [30] (a single `srli 30` peels both routing bits), `size` at [7:0] (`andi 0xFF`). Those three are the fabric's only commitment; `op[29:24]` is reallocated per personality.

A payload **address word** (`dst_slot`) names the destination inside the consumer: **upper bits select which BRAM** in the consumer's local BRAM array, lower bits the offset within.

Representative payloads (logic-sim personality):

```
size=0  op-only:     barrier_ack, wake, free_slot, heartbeat
size=1  logic delta: word1 = [31:16] value,    [15:0] dst_slot
size=1  event post:  word1 = [31:16] event_id, [15:0] dst_slot
size=2  wide value:  word1 = (dst_slot, src_id), word2 = value
size=k  vector:      word1 = (dst_slot_base, stride), words2..k+1 = vector
```

The NIF writes words 1..size first and commits word 0 last, raising ready one cycle after — the slot is atomically visible at the ready flip; the consumer never sees a half-written slot. `op.wide` reinterprets the payload as a pointer into shared scratchpad for the rare oversize tail.

## Addressing and banking

The consumer's signal store is an array of BRAMs; each block holds its mailbox slots at the base and its signal regions above. **`bank_id` — which BRAM — is fixed in the address** (the upper bits of `dst_slot`); nothing about it flips.

`addr_mode` (word 0, [30]) chooses how the lower address is interpreted *within* the selected BRAM, and that meaning follows the op-code:

- **`addr_mode=0`** — absolute offset from the **base of the BRAM**. Non-banked regions: config, LUTs, scratchpad, debug.
- **`addr_mode=1`** — offset from **`region_base`**, a **per-BRAM register** holding the base of that block's active/inactive (clocked-signal) region (above the mailbox slots at the block base; not known a-priori, programmed at config/boot). The target-specific **active/inactive op-code bit** lands (shifted) in the region-select bit of the offset, **XOR'd with a one-bit cycle parity that flips every cycle**. Active and inactive are two *fixed* regions; the parity re-aliases which is which each cycle.

Because the parity flips with the cycle counter, a value deposited to **inactive** this cycle is addressed as **active** next cycle — a double buffer by **addressing alone: zero data movement, no flip command**. The hardware never moves a value between regions and never triggers processing on its own:

- **deposit to inactive** = deferred (NBA-like): the consumer's dispatch reads it as active on a later cycle and processes it then — software-managed.
- **deposit to active** = live this cycle, and *may* carry a follow-on routine call (the consumer eval that processes it). That follow-on — what `trigger` used to be — is a personality dispatch decision, not a fabric bit.

## Consumer dispatch

A handful of instructions classify a packet completely:

```asm
loop:
  csrr   t0, ready_mask
  beqz   t0, idle
  ctz    t1, t0                          # first ready slot
  lw     t2, 0(slot_base + t1*SLOT_BYTES)# word 0
  bltz   t2, off_array_handler           # off_array == sign bit
  andi   t3, t2, 0xFF                    # size_words
  srli   t4, t2, 24                      # off_array, addr_mode, op in low bits
  # ... dispatch on op via the personality jump table; read words 1..size as needed
  csrrc  x0, ready_mask, 1 << t1
  csrrs  x0, free_mask,  1 << t1
  j      loop
idle:
  wfi                                    # NIF raises ready_mask -> wake
  j      loop
```

No decode dependency chain — `bltz`, size, and op peel out independently. A core whose `ready_mask` drains issues `wfi` and burns zero clocks until the NIF raises ready, so idle phases cost nothing in dynamic power.

**The processor runs this drain in software, when it has nothing else to do** — after its local
events are exhausted it turns to the mailbox. That's the baseline (and the M1 target). The drain
*can* be hardware-accelerated later (a dispatch engine that applies deposits without waking the
core), but software-first keeps the fabric minimal and the personality in charge.

## Producer send

`ctz(free_mask)` for a slot, write payload then commit word 0 through a CSR-mapped window, ring a `send` doorbell with the slot id. The NIF ships it (gated by `off_array`) and on delivery-ack restores the `free_mask` bit. Outgoing slots never touch `ready_mask`. A short per-destination output FIFO (4–8 deep) absorbs bursts so one full destination can't stall the producer's other links.

## Quiescence and barrier

"Cannot advance the cycle while any work is pending." All three must be zero:

```
any_busy  = OR over cores (state != WFI || ready_mask != 0)
in_flight = Σ over network (sent − delivered)     # per-NIF delivery credits, summed up the tree
nif_busy  = OR over NIFs (tvalid on any link)
quiescent = !any_busy && in_flight == 0 && !nif_busy
```

Hold `quiescent` for one barrier-tree depth (~log N cycles) to absorb the last in-flight settling, then advance the cycle: the addressing parity flips (no command, no data movement), so this cycle's inactive deposits are now addressed as active; consumers wake via incoming ready bits and process them, and the next cycle starts. The barrier is an AND-tree of per-core `done` flags to a coordinator — 6 deep on an 8×8 array, under one clock at 200 MHz post-PAR.

## Off-array routing

Off-array packets address the **host-bridge process** — a process whose handle lies outside the on-array `(y,x)` range. `op.off_array == 1` (or a `(dst_y,dst_x)` out of range) routes the whole packet, undecoded, to the egress NIF. This is not a list of fabric-handled tasks: host-effecting system tasks are *compiled* into messages to that process carrying only their **runtime args**; everything static is registered host-side at compile/boot and keyed by the handle. On the ZCU104 the host-bridge **is the ARM PS**: egress packets cross PL→PS (AXI/DMA), and the ARM — holding the static per-handle tables — performs the actual effect (e.g. `printf`). In simulation the testbench plays this ARM role (captures egress, formats, prints).

`$display(format, args)` lowers to an off-array message whose payload is just `{args}` (size = arg-word count); the `(dst_y,dst_x)` handle names the call site, and the **ARM** holds that site's format string and file and runs the actual `printf`. The format never ships at runtime — only the values. The same shape covers the family:

- `$write/$strobe/$monitor/$fwrite` — call-site handle (format + file) + arg payload.
- `$fatal/$error/$warning` — severity in op, message handle + args.
- `$finish/$stop` — op-only control to the host-bridge.
- DPI — function handle in `(y,x)`, args as payload, result returned as an inbound message.

Pure-compute functions (`$urandom`, `$random`) do **not** go off-array — they are local per-thread or shared-stream processes on the array (see Integration). Multicycle egress is fine: these are monitor-region effects deferred to end-of-timestep; the host-bridge serializer reorders by source-timestamp before emitting.

## Backpressure

`free_mask & slot_mask == 0` → the local NIF holds AXI-Stream `tready` low; producers feel it through their own stuck `tvalid`. A watchdog on `tready`-held-low > N cycles flags potential deadlock to the coordinator — real deadlocks here are almost always a partitioning bug, not transient congestion.

## Boot

At reset `slot_limit = 32`, all slots visible. The coordinator's first packets are config that program each core's `slot_limit`, `region_base`, and op tables to its workload — no reservation, no chicken-and-egg, a default-wide state that narrows once the personality loads. The compiler emits the per-core tables in the boot image.

## Sizing — ZCU104 / XCZU7EV (312 BRAM36, 96 URAM288)

- **Slot files**: distributed LUTRAM, or a slice of BRAM; generous default, spare capacity repurposed.
- **Dedicated per-edge BRAM**: 1 BRAM36 per cut edge — ~17-core fully-connected mesh, or 60+-core sparse at 4–8-neighbor fan-out.
- **High-fanout consumers**: 1 URAM288 absorbs 32 producers × 256 slots.
- Memory is not the constraint; port-B fan-in past ~8 producers is, and gets arbitrated through AXI-Stream FIFOs there.

## Configurations

Synthesis-parameterized `(N_SLOTS ≤ 32, SLOT_WORDS, WORD_WIDTH)`; `slot_limit` narrows at runtime without a rebuild.

- **Logic-sim default**: 32 × 4 × 32 — generous.
- **RTL co-sim with bus traffic**: 32 × 8 × 64.
- **Control-plane only**: 32 × 1 × 32 — op-only event signaling.

## Integration

- **NVC** — LLVM backend retargets to RV32; runtime swaps to mailbox primitives (signal assign → post, wait → dispatch, `$display` → off-array).
- **pp** — Verilog front-end desugars to the same IR and primitives.
- **Mylex** — emits ONNX-graph partitions, per-core `slot_limit`, op tables, dispatch code.
- **ldx** — federates cross-language / cross-cluster boundaries, same model as the NVC/Xyce federation; mailbox primitives are interposable via `dlreplace`/`dlreplaceq`.
- **OAE** — off-cluster transport for `off_array` packets, through the existing protocol RTL generation.

## Open

- Slot-file placement: LUTRAM in core vs dedicated dual-ported BRAM next to it — default LUTRAM, promote only if NIF/core arbitration shows in timing.
- `in_flight` credit-accounting depth, and the host-side reorder-buffer depth for off-array event ordering across cores.
- `wide` scratchpad pointers: absolute vs core-local, and when the region is reclaimed.
