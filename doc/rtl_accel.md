# RTL acceleration — DUT on the array, testbench on the ARM

The market and the near-term focus: **accelerate a DUT's RTL on the core array, with the user's
testbench running normally on the ARM.** This is the practical form of the M3c flow and it drops the
hardest parts of "whole sim on the array."

## The model

- **DUT → array.** The synthesizable RTL is lowered by `--accel`/yosys to state-machine C, partitioned
  (mesh_place), and each piece recompiled for its target core (M3c.0/.1/.2 — proven). Cross-core DUT
  nets ride the mailbox.
- **TB → ARM.** The testbench stays on the ARM as ordinary host code: stimulus, `$display`, checking,
  file I/O all run natively. **No TB lowering, no re-JIT, no `$display`-as-process** — the things that
  made "whole sim on the array" hard are simply not needed here.
- **Boundary = the DUT's top-level I/O.** The ARM drives DUT top-inputs in and reads DUT top-outputs
  back each cycle. We already have **egress** (array→ARM, the host-bridge). The missing piece is
  **host ingress** (ARM→array) to drive top-inputs — the ARM becomes an off-array node that posts to
  the input-owning core, symmetric with the egress host-bridge.

This is the same shape as today's single-process `--accel` (TB drives, accel offloads the DUT logic),
but with the DUT **distributed across the array** and the host being the **ARM PS**.

## Credit accounting at the host boundary

The barrier's in-flight credits must stay balanced with host traffic:
- on-array post: `pkt_sent`(producer) + `pkt_deliv`(consumer) — balanced.
- egress (core→ARM): `pkt_sent` is **excluded** (off_array), no on-array deliver — balanced (0).
- ingress (ARM→core): the core's rx commit gives `pkt_deliv`, so the **host injection must emit a
  matching `pkt_sent`** (the ARM is the sender) — else `in_flight` underflows and the barrier hangs.

## Cycle stepping

The barrier still auto-advances on quiescence (the DUT settles within a cycle). The ARM injects the
top-inputs for the next cycle and reads the top-outputs of the current one, stepping in lockstep with
`cycle_advance` — exactly how an on-array producer drove M3c.1, now sourced from the host.

## First demo (raccel.0)

The **consumer** (`result <= (x^5)+1`) as a **1-core DUT**; the ARM (the sim TB) drives `x = 0,1,2,…`
in via **host ingress** and reads `result` out via egress, checking against the software golden. Same
`0 6 5 8 7 …` result as M3c.1 — but the stimulus now comes from the host, proving the ARM↔DUT boundary
and "accel-C per core + TB on ARM." Then: multi-core DUT (a real pipeline), bigger real RTL. Yuri is
deferred (too small).

## Build pieces

1. **host ingress** — a router input for the host (parameterized `HOST_INGRESS`), routed to cores by
   dst; `mb_array_soc` `ingr_*` port; barrier `pkt_sent` credit on the ingress last beat.
2. **1-core DUT runtime** — receive `x` from ingress, eval, post `result` to egress.
3. **TB-on-ARM** (`tb_raccel.sv`) — drive `x`, read `result`, diff vs golden.
