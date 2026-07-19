# Mailbox ↔ existing core integration — scoping

**There is no new core to pick.** The core is **VexRiscv**, already integrated in
`fpga/zcu104/rtl/ldx_soc_mesh.v` (VexRiscv + `ldx_cfu` CFU plugin + a gate-compute fetch hook +
4 KB dual-port BRAM). The mailbox is **mostly an add-on**: VexRiscv's dBus already does MMIO, and
today it drives the **4-direction N/E/S/W mesh FIFOs** — precisely the nearest-neighbor routing the
mailbox replaces with the flat `(dst_y,dst_x)` namespace. **No VexRiscv changes needed** — just MMIO
+ one interrupt. The behavioral `mb_core` was a sim stand-in; the real node is this SoC. Companion
to [mailbox.md](mailbox.md).

## What's already there (reuse)

- **VexRiscv** core: iBus (BRAM port A), dBus (MMIO + BRAM port B), `CfuPlugin` bus, and an unused
  `externalInterrupt`.
- **MMIO pattern**: `0x8xxxxxxx`=BRAM, `0xFxxxxxxx`=IO. The IO decode (`0xF1x0..0xF1x C` per dir)
  is the mesh FIFO push/pop — the template for the mailbox registers. `0xF...040` already returns
  `{MY_Y,MY_X}`. `0x000..0x00F` is a reserved "older mailbox slot."
- **`ldx_cfu` + gate-compute hook** (`gate_vtable_decode` + `gate_alu_v4`): a hardware logic-eval
  accelerator that borrows BRAM port B on a vtable fetch — complementary to the mailbox (it's how
  "regular event processing" can be sped up); leave it in place.

## The add-on

Replace the 4-direction FIFO IO block with the mailbox fabric I already built and sim-validated
(`mb_slot_file`, `mb_nif`, `mb_signal_port`, `mb_router`, `mb_barrier`). The CPU drives it over the
**same dBus MMIO mechanism** it uses for the FIFOs today; the node has **one** network port (the
NIF's AXI-Stream) to `mb_router` instead of four directional FIFOs.

Proposed MMIO map (in the `0xF...` IO window, replacing `0xF1xx`):
```
0xF000_0000  READY_MASK    (R)  32-bit ready bitmap
0xF000_0004  FREE_MASK     (R)  32-bit free bitmap
0xF000_0008  SLOT_LIMIT    (RW)
0xF000_000C  MAILBOX_BASE  (RW) BRAM offset of the slot region (NIF + CPU both use it)
0xF000_0010  REGION_BASE   (RW) BRAM offset of the active/inactive signal region
0xF000_0014  SEND_W0       (W)  direct-send word0  ─┐ ring doorbell on payload write
0xF000_0018  SEND_D1       (W)  direct-send payload ┘
0xF000_001C  DONE_SLOT     (W)  free a drained slot (clears ready, sets free)
0xF000_0040  MY_YX         (R)  {MY_Y,MY_X}   (already present)
```
Incoming slots and the signal regions live **in the node BRAM** (at `MAILBOX_BASE` / `REGION_BASE`);
the CPU reads incoming messages and its signals with **ordinary loads** — no separate slot window.
The NIF writes incoming messages into the BRAM (a port-B writer, arbitrated like the gate unit).

## Signals & banking

**The BRAM setup is unchanged** — the mailbox is the long-reach add-on, not a new memory. Per BRAM
block: **mailbox slots at the base**, signal regions above. The clocked active/inactive
(double-buffered) signal region sits at a **per-BRAM `region_base` register**. `mb_signal_port` is
on the deposit write path: `addr_mode` + the active/inactive bit live in the store **address**,
`cycle_parity` is XOR'd at the port and is invisible to the core; deposit-to-active vs -inactive is
just a store with the right address bits (compiler-emitted). The gate-compute hook already writes
the BRAM via port B; the signal port is the same idea on the mailbox-deposit path.

**The processor drains the mailbox in software, when it has nothing else to run** (after local
events are exhausted) — that's the M1 baseline. A dispatch accelerator that applies deposits without
waking the core is a later option, not now.

## wfi / wake / barrier

- `externalInterrupt` ← `ready_mask != 0` (NIF committed an incoming packet) | `cycle_advance`.
- Core issues `wfi` when idle; the interrupt wakes it to drain / start the next cycle.
- Node `core_busy` = `!in_wfi || ready_mask != 0` → `mb_barrier`; the barrier's in-flight credits
  (already built) hold the cycle until all packets land.

## Fabric reuse vs new glue

- **Reuse as-is**: `mb_slot_file`, `mb_nif` (incl. direct-send + credits), `mb_signal_port`,
  `mb_router`, `mb_barrier` — all sim-validated.
- **New glue**: a **dBus↔mailbox MMIO adapter** (maps VexRiscv dBus reads/writes to the slot-file
  rd/free + NIF send + CSR regs — replacing the FIFO decode), a node wrapper
  `ldx_soc_mailbox.v` (VexRiscv + CFU + BRAM + mailbox MMIO + signal port), and an array top
  (grid of nodes + `mb_router` + `mb_barrier` — i.e. `mb_array` with the real node in place of the
  behavioral `mb_tile`).

## Milestones

- **M1** — `ldx_soc_mailbox.v`: VexRiscv SoC with the mailbox MMIO replacing the mesh FIFOs.
  Hand-write a C dispatch loop (drain ready → deposit → free; send via SEND_W0/D1; `wfi`).
  Sim one node: VexRiscv runs the program and sends/receives over the mailbox.
- **M2** — 4×4 of these nodes + `mb_router` + `mb_barrier`; re-run the ring as *real* software.
- **M3** — NVC-lowered tiny design (DUT + TB + a `$display`) running on the array — whole sim on
  the array, no host TB.

## Decided (2026-06)
- **BRAM setup unchanged**; the mailbox is the long-reach add-on, **replacing** the 4-dir mesh FIFOs.
- Slot region placed wherever fits, pointed to by a **`mailbox_base` register**; clocked
  active/inactive signal region at a **`region_base` register**. NIF writes incoming into the BRAM
  at `mailbox_base`; the CPU reads with ordinary loads.
- **Mailbox drain = the processor, in software, when idle**; HW acceleration is a later option.

## Still to confirm
1. **Replace or coexist**: drop the 4-dir mesh FIFOs entirely, or keep them alongside during bring-up?
2. **MMIO map for the CSRs** (ready/free/slot_limit/region_base/doorbell/done): the layout above, or
   align to the existing `0xF1xx` offsets?
3. **M1 program**: hand-written C dispatch loop first (recommended), before NVC-lowering?
