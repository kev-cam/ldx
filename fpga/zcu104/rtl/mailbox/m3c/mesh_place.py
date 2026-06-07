#!/usr/bin/env python3
"""mesh_place.py — yosys-driven placement of an RTL design onto the N×N softcore mesh.

Pipeline:
  1. Synthesize the design to a gate-level netlist with yosys (-> JSON).
  2. Build a connectivity hypergraph (cells = nodes, nets = hyperedges).
  3. Place cells onto the N×N mesh with recursive min-cut bisection
     (alternating X/Y axis, balanced halves) so connected logic lands on
     adjacent cores — this is the locality the mesh needs to win, since every
     net cut across a core boundary costs a mesh hop every clock edge.
  4. Emit cell->(x,y)/core assignment and report the cut-net count vs a
     round-robin baseline.

Output: a placement file (cell, core_id, x, y per line) consumable by the
engine as a partition assignment.

Usage:
  mesh_place.py -N 5 -o place.txt design.v [more.v ...]
  mesh_place.py -N 5 --top tb --incdir . design.sv ...
"""
import argparse, json, subprocess, sys, os, tempfile


def run_yosys(files, top, incdirs, params=None, no_flatten=False):
    """Synthesize and return parsed JSON. Default: flattened gate netlist (cells =
    gates). no_flatten: keep hierarchy so cells = module INSTANCES (instance-level
    partitioning — cuts land on the design's natural, usually registered, boundaries)."""
    jf = tempfile.NamedTemporaryFile(suffix=".json", delete=False).name
    inc = "".join(f" -I{d}" for d in incdirs)
    reads = "\n".join(f"read_verilog -sv{inc} {f}" for f in files)
    chp = "".join(f" -chparam {k} {v}" for k, v in (params or {}).items())
    topcmd = (f"hierarchy -top {top}{chp}" if top else "hierarchy -auto-top")
    body = ("proc\nopt_clean" if no_flatten else
            "proc\nflatten\nopt\nmemory\nopt\ntechmap\nopt\nclean")
    script = f"""
{reads}
{topcmd}
{body}
write_json {jf}
"""
    sf = tempfile.NamedTemporaryFile(suffix=".ys", delete=False, mode="w")
    sf.write(script); sf.close()
    r = subprocess.run(["yosys", "-q", "-s", sf.name],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit("yosys synthesis failed")
    with open(jf) as f:
        return json.load(f)


def build_graph(netlist, top):
    """Return (cells, nets) where cells is a list of names and nets maps a net
    id to the set of cell indices that touch it."""
    mods = netlist["modules"]
    if top and top in mods:
        mod = mods[top]
    else:
        # pick the module with the most cells
        top = max(mods, key=lambda m: len(mods[m].get("cells", {})))
        mod = mods[top]

    cells = list(mod.get("cells", {}).items())
    names = [n for n, _ in cells]
    nets = {}  # net bit id -> set(cell idx)
    for idx, (_, cell) in enumerate(cells):
        for bits in cell.get("connections", {}).values():
            for b in bits:
                if isinstance(b, int):          # skip constants "0"/"1"/"x"
                    nets.setdefault(b, set()).add(idx)
    # drop nets touching <2 cells (no cut possible) for the cut metric
    hyper = {n: cs for n, cs in nets.items() if len(cs) > 1}
    return names, nets, hyper, top


def adjacency(n_cells, hyper):
    """Cell->set(neighbor cell) from the hypergraph (clique expansion)."""
    adj = [set() for _ in range(n_cells)]
    for cs in hyper.values():
        cl = list(cs)
        for i in cl:
            for j in cl:
                if i != j:
                    adj[i].add(j)
    return adj


def bfs_order(members, adj):
    """Order a subset of cells by BFS so connected cells are contiguous."""
    mset = set(members)
    seen, order = set(), []
    # seed with the lowest-degree member (a corner of the cluster)
    for seed in sorted(members, key=lambda c: len(adj[c] & mset)):
        if seed in seen:
            continue
        queue = [seed]; seen.add(seed)
        while queue:
            c = queue.pop(0); order.append(c)
            for nb in sorted(adj[c] & mset):
                if nb not in seen:
                    seen.add(nb); queue.append(nb)
    return order


def place(members, adj, x0, y0, w, h, coord):
    """Recursively bisect `members` into the w×h mesh sub-rectangle whose
    lower corner is (x0,y0). Splits the longer axis, BFS-order median cut."""
    if w == 1 and h == 1:
        for c in members:
            coord[c] = (x0, y0)
        return
    order = bfs_order(members, adj)
    if w >= h:                       # split along X
        wl = w // 2
        cut = int(round(len(order) * wl / w))
        place(order[:cut], adj, x0,      y0, wl,     h, coord)
        place(order[cut:], adj, x0 + wl, y0, w - wl, h, coord)
    else:                            # split along Y
        hl = h // 2
        cut = int(round(len(order) * hl / h))
        place(order[:cut], adj, x0, y0,      w, hl,     coord)
        place(order[cut:], adj, x0, y0 + hl, w, h - hl, coord)


def cut_nets(hyper, cell_core):
    """Number of nets that span more than one core (each = a mesh hop/edge)."""
    return sum(1 for cs in hyper.values()
               if len({cell_core[c] for c in cs}) > 1)


# ---------------------------------------------------------------------------
# Timing-aware analysis. The lock-step mesh simulation has the same critical
# paths as the design: each clock edge can't finish until the longest chain of
# dependent combinational evaluations settles, and every partition boundary
# that chain crosses costs Manhattan hop-distance on a nearest-neighbour mesh.
# So the objective is not cut COUNT but the worst accumulated hop-distance along
# a dependency chain — and the far/critical nets are the ones to lift onto
# express channels or plain dedicated wires.
# ---------------------------------------------------------------------------
def is_seq(cell_type):
    t = cell_type.lower()
    return "dff" in t or "dlatch" in t or t.startswith("$_dff") or "$_sdff" in t


def build_dag(mod):
    """Per cell: sequential?, input net bits, output net bits, and net->driver."""
    cells = list(mod.get("cells", {}).items())
    n = len(cells)
    seq = [False] * n
    ins = [[] for _ in range(n)]
    driver = {}
    for idx, (_, cell) in enumerate(cells):
        seq[idx] = is_seq(cell.get("type", ""))
        dirs = cell.get("port_directions", {})
        for port, bits in cell.get("connections", {}).items():
            d = dirs.get(port, "input")
            for b in bits:
                if not isinstance(b, int):
                    continue
                if d == "output":
                    driver[b] = idx          # assume single driver per net
                else:
                    ins[idx].append(b)
    return seq, ins, driver


def comb_depth(n, seq, ins, driver):
    """Longest combinational gate-depth feeding each cell (registers/PIs are
    depth boundaries). max over cells = the design's combinational critical path."""
    depth = [None] * n
    sys.setrecursionlimit(1 << 22)

    def d(i, stack):
        if depth[i] is not None:
            return depth[i]
        if i in stack:                       # comb loop guard
            return 0
        stack.add(i)
        best = 0
        for b in ins[i]:
            drv = driver.get(b)
            if drv is None or drv == i:
                continue
            best = max(best, 1 if seq[drv] else 1 + d(drv, stack))
        stack.discard(i)
        depth[i] = best
        return best

    for i in range(n):
        d(i, set())
    return depth


def crit_hops(n, seq, ins, driver, coord, express=False):
    """Worst accumulated mesh hop-distance along a dependency chain (the
    simulation's per-edge critical path), plus the per-edge hop list for
    picking express/wire candidates. Edge weight = Manhattan(core_drv, core_sink).
    With express=True, any cut edge costs a single hop (models express channels
    that collapse multi-hop links to one)."""
    def mh(a, b):
        d = abs(coord[a][0] - coord[b][0]) + abs(coord[a][1] - coord[b][1])
        return (1 if d > 0 else 0) if express else d

    best_to = [None] * n
    edges = []  # (hopdist, driver_idx, sink_idx)

    def c(i, stack):
        if best_to[i] is not None:
            return best_to[i]
        if i in stack:
            return 0
        stack.add(i)
        best = 0
        for b in ins[i]:
            drv = driver.get(b)
            if drv is None or drv == i:
                continue
            w = mh(drv, i)
            if w > 0:
                edges.append((w, drv, i))
            best = max(best, w if seq[drv] else w + c(drv, stack))
        stack.discard(i)
        best_to[i] = best
        return best

    worst = max((c(i, set()) for i in range(n)), default=0)
    return worst, edges


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("-N", type=int, default=5, help="mesh dimension (N×N)")
    ap.add_argument("--top", default=None)
    ap.add_argument("--incdir", action="append", default=[])
    ap.add_argument("--chparam", action="append", default=[],
                    help="override a top parameter, e.g. --chparam width=4")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--no-flatten", action="store_true",
                    help="partition at module-instance granularity (cells = instances)")
    args = ap.parse_args()

    params = dict(kv.split("=", 1) for kv in args.chparam)
    nl = run_yosys(args.files, args.top, args.incdir, params, args.no_flatten)
    names, nets, hyper, top = build_graph(nl, args.top)
    n = len(names)
    N = args.N
    print(f"design '{top}': {n} cells, {len(hyper)} multi-cell nets, mesh {N}×{N}")
    if n == 0:
        sys.exit("no cells to place")

    adj = adjacency(n, hyper)
    coord = {}
    place(list(range(n)), adj, 0, 0, N, N, coord)
    cell_core = {c: coord[c][0] * N + coord[c][1] for c in range(n)}

    # baseline: round-robin assignment
    rr = {c: c % (N * N) for c in range(n)}

    placed_cut = cut_nets(hyper, cell_core)
    rr_cut = cut_nets(hyper, rr)
    load = [0] * (N * N)
    for c in range(n):
        load[cell_core[c]] += 1
    used = sum(1 for l in load if l)
    print(f"cut nets (cross-core):  placed={placed_cut}  round-robin={rr_cut}"
          f"  -> {(1 - placed_cut / rr_cut) * 100:.0f}% fewer" if rr_cut else
          f"cut nets: placed={placed_cut}")
    print(f"cores used: {used}/{N*N}   load min/max: {min(load)}/{max(load)}")

    # ---- timing-aware analysis: critical path & heterogeneous interconnect ----
    mod = nl["modules"][top]
    seq, ins, driver = build_dag(mod)
    depth = comb_depth(n, seq, ins, driver)
    cpd = max(depth) if depth else 0
    worst, edges = crit_hops(n, seq, ins, driver, coord)
    worst_x, _ = crit_hops(n, seq, ins, driver, coord, express=True)
    print(f"combinational critical-path depth: {cpd} gate levels")
    print(f"critical-path mesh cost: {worst} hops/edge"
          f"  ->  {worst_x} with express channels"
          + (f"  ({(1 - worst_x / worst) * 100:.0f}% lower)" if worst else ""))

    # High-fanout nets — clock/reset/global control. Packetizing these through
    # the router is hopeless; route them as dedicated wires.
    fan = sorted(((len(cs), b) for b, cs in nets.items()), reverse=True)[:5]
    print("dedicated-wire candidates (highest fanout — likely clk/rst/global):")
    for fo, b in fan:
        print(f"  net#{b}: fanout {fo}")

    # Longest critical edges between distinct cores — express-channel candidates.
    edges.sort(reverse=True)
    seen, picks = set(), []
    for w, dr, sk in edges:
        key = (cell_core[dr], cell_core[sk])
        if key in seen:
            continue
        seen.add(key)
        picks.append((w, dr, sk))
        if len(picks) >= 6:
            break
    print("express-channel candidates (longest critical links):")
    for w, dr, sk in picks:
        print(f"  core{cell_core[dr]}{coord[dr]} -> core{cell_core[sk]}{coord[sk]}"
              f"  {w} hops  (sink depth {depth[sk]})")

    if args.output:
        with open(args.output, "w") as f:
            f.write(f"# cell core_id x y   (mesh {N}x{N}, top {top})\n")
            for c in range(n):
                x, y = coord[c]
                f.write(f"{names[c]} {cell_core[c]} {x} {y}\n")
        print(f"wrote placement -> {args.output}")


if __name__ == "__main__":
    main()
