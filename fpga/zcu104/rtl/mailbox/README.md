# Mailbox array fabric — RTL skeleton

SystemVerilog skeleton for the array communication fabric in
[`../../../../doc/mailbox.md`](../../../../doc/mailbox.md). The fabric is pure
routing + addressing; all Verilog scheduling-region semantics live in a
target-specific op-code decoded by the core software (the "personality"), not
the hardware.

## Module map

| File | Role | Status |
|---|---|---|
| `mailbox_pkg.sv`   | params, Word-0 layout, field pack/unpack, personality + signal-store geometry | usable |
| `mb_slot_file.sv`  | 32-slot message RAM (LUTRAM) + `free`/`ready` bitmaps + allocator | core logic in |
| `mb_signal_port.sv`| port-B deposit address calc: `bank_id` fixed, `addr_mode`, `op_bit ⊕ cycle_parity` | core logic in |
| `mb_nif.sv`        | AXI-Stream rx/tx, slot alloc+commit+ready, `off_array` egress, backpressure | FSM skeleton |
| `mb_barrier.sv`    | quiescence (`!any_busy && in_flight==0 && !nif_busy`) + cycle-parity flip | usable |
| `mb_tile.sv`       | core + slot file + NIF + signal port + banked BRAM wire-up | wiring; core = TODO |
| `mb_array.sv`      | `ARRAY_Y×ARRAY_X` tile grid + router + barrier | structural |
| `mb_router.sv`     | flat-namespace switch / egress | **STUB** |

## Key decisions baked in
- **≤ 32 slots** → `free`/`ready`/alloc are single-word 32-bit bitmap ops.
- **`bank_id` (which BRAM) is fixed** in the `dst_slot` upper bits — never flips.
- **`addr_mode`**: 0 = absolute BRAM offset; 1 = `region_base`(reg) + offset with
  the region-select address bit = `op[ACTIVE_INACTIVE] ⊕ cycle_parity`.
- **`cycle_parity`** is the one free-running bit (flipped by the barrier at cycle
  advance) — active/inactive is a double buffer by addressing alone, no copy, no
  flip packet.

## TODO (the real work)
1. **Core shim** — drop in an RV32 (PicoRV32 / VexRiscv / Ibex); map CSRs
   (`free`/`ready`/`slot_limit`/`region_base`), loads/stores to slot RAM +
   signal-BRAM port A, the `send` doorbell, deposits to the signal port, and
   `done` (csrrc ready / csrrs free).
2. **mb_router** — arbitrated crossbar / sparse NoC sized to the graph cut set;
   header dst decode + `off_array` egress.
3. **Delivery-ack + credits** — ack packets back to senders (free outgoing slot);
   `n_sent`/`n_deliv` into the barrier's `in_flight`.
4. **Dedicated dual-port BRAM path** — header-less per-edge bulk deltas (port B).
5. Real dual-port BRAM macros for the signal store; lock `REGION_SEL_BIT` /
   `region_base` to the per-personality signal address map.

## Lint / elaborate
```
verilator --lint-only -sv -Wno-fatal --top-module mb_array \
  mailbox_pkg.sv mb_slot_file.sv mb_signal_port.sv mb_nif.sv \
  mb_barrier.sv mb_router.sv mb_tile.sv mb_array.sv
```
