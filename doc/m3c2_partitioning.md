# M3c.2 — automatic partitioning + per-core codegen, then a real DUT

Turn M3c.1's hand-partitioning + hand-written runtime into an automatic flow: read the design, decide
the cut, emit the placement map and the per-core programs, validate against the unsplit golden, then
point it at a real DUT (Yuri `a_plus_b`). Builds on [m3c_lowering.md](m3c_lowering.md).

## Reuse the leftover P&R partitioner (`mesh_place.py`)

`ldx/examples/rtl-sim/mesh_place.py` already does the "place-and-route guess at partitioning":
yosys-synthesize → build a connectivity **hypergraph** (cells = nodes, nets = hyperedges) → **recursive
min-cut bisection** (BFS-ordered median cut, alternating X/Y) onto an N×N mesh → emit `cell core_id x y`
plus **cut-net count**, **combinational critical-path depth**, **high-fanout (clk/rst/global) candidates**,
and **express-channel** (longest critical link) candidates. This is the partitioner for M3c.2 — it
matches our yosys flow and already reports exactly what the mailbox routing needs (which nets cross a
cut, and the chains that bound settling). (`rtl_partition.c/.h` has connectivity/timing/hierarchical
strategies too but is tied to the old `rtl_sim_engine` gate model — keep for reference.)

## The automatic pipeline (extends M3c.1)

```
1. place    mesh_place.py -> cell/instance -> core, cut-net list, critical-path depth
2. split    yosys -> one synthesizable submodule per core; each cut-net becomes a boundary PORT
3. generate gen_statemachine per submodule -> sm_eval + sm_ports[] (the boundary table)
4. map      auto-emit the placement map: core->submodule, cut-net -> edge (matched by net/port NAME,
            producer core's output port X -> consumer core's input port X), state/io BRAM addrs,
            $display handles, service placement (ARM host-bridge, RNG core)
5. codegen  per-core runtime from the map: N-way dispatch on node id; cross-core posts/receives by
            DIRECT field access (sm_ports field names) — NOT runtime-offset reads (the -Os miscompile
            from M3c.1); no memcpy/memset needed
6. verify   diff the array's $display stream against the UNSPLIT golden (native sm_eval), as in M3c.0/.1
7. DUT      Yuri a_plus_b partitioned across N cores -> the headline "real sim on the array"
```

## Granularity + cut handling (decisions)

- **Start instance/module-level** (coarse): partition whole module instances, so cut-nets land on the
  design's natural — usually registered — interfaces. Yuri `a_plus_b` is ideal (FIFO_A / FIFO_B /
  FIFO_SUM / adder → one per core; cuts = the FIFO push/pop/data ports). Run `mesh_place` **without
  flatten** (cells = instances) to get the instance→core cut. Registered cuts stay lockstep — the
  proven M3c.1 path.
- **Then gate-level** (mesh_place's native mode) for finer balance on bigger blocks. Gate cuts are
  combinational, so a cross-core edge can fire mid-cycle → use **M3b's within-cycle delta settling**
  (the consumer re-evals when an input arrives; the barrier holds until global quiescence). The number
  of delta rounds is bounded by mesh_place's **critical-path depth** × boundary crossings.

## Open issues

- **yosys per-core submodule split** — the mechanism to carve the placed netlist into N modules with
  cut-nets exposed as ports (`submod`/`select` + port synthesis). The crux of step 2.
- **High-fanout nets** (clk/rst/global) — mesh_place already flags these; they are NOT mailbox edges
  (clock/reset are the barrier/parity; true global signals get a dedicated broadcast, not a per-edge post).
- **Combinational-cut convergence** — only for gate-level; registered cuts avoid it.
- **Load balance vs cut** — mesh_place reports both (`load min/max`, `cut nets placed vs round-robin`);
  pick the strategy per design.
- **Service placement** — the map reserves cores for the **RNG** service and routes `$display` to the
  **ARM host-bridge**; the partitioner must leave room / not place DUT logic on service cores.
- **Codegen field access** — emit DIRECT `o._x` (names from sm_ports); never runtime-offset (-Os).

## First step — M3c.2.0

Re-derive M3c.1's split **automatically**: run `mesh_place` on a small modular design (the prodcons
pair, or a 3–4 module design) for N=2, auto-emit the placement map + per-core codegen, and confirm it
reproduces the M3c.1 PASS (array == unsplit golden) with **no hand-partitioning**. Then scale N and
point it at Yuri `a_plus_b`.
