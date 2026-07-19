#!/usr/bin/env python3
"""m3c2_partition.py — auto-derive the array placement map from a design.

Reuses mesh_place's yosys front-end to get an instance-level netlist, then:
  - finds cross-instance nets and their DIRECTION (which instance's output port
    drives them, which instances read them) -> the cross-core mailbox edges;
  - drops clk/rst/globals (no instance drives them; they are the barrier/parity);
  - topologically orders the partitions (producers before consumers) and lays
    them onto the array nodes;
  - marks instance outputs that reach a top-level output as $display.
Emits the same placement-map JSON the hand-written M3c.1 map used, so genmap.py
+ the per-core runtime consume it unchanged. No hand-partitioning.

Usage: m3c2_partition.py --top top2 -o m3c2.map producer.v consumer.v top2.v
"""
import sys, json, argparse
import mesh_place

GLOBAL_PORTS = {"clk", "clock", "rst", "reset", "rstn", "resetn", "clk_i", "rst_i"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--top", required=True)
    ap.add_argument("-o", "--output", required=True)
    args = ap.parse_args()

    nl = mesh_place.run_yosys(args.files, args.top, [], None, no_flatten=True)
    mods = nl["modules"]
    top = mods[args.top]
    cells = top["cells"]                       # instance -> {type, connections}
    insts = list(cells.keys())

    # module port directions, keyed by module type
    pdir = {mt: {p: d["direction"] for p, d in m.get("ports", {}).items()}
            for mt, m in mods.items()}

    # net bit -> list of (inst, port, dir)
    netmap = {}
    for inst, c in cells.items():
        dirs = pdir.get(c["type"], {})
        for port, bits in c.get("connections", {}).items():
            d = dirs.get(port, "input")
            for b in bits:
                if isinstance(b, int):
                    netmap.setdefault(b, []).append((inst, port, d))

    # top-level output nets -> ports that should $display
    top_out_bits = set()
    for pname, p in top.get("ports", {}).items():
        if p["direction"] == "output":
            top_out_bits.update(b for b in p["bits"] if isinstance(b, int))

    # cross-instance edges: (src_inst, src_port, dst_inst, dst_port) ; and displays
    edges = {}
    displays = {}                              # inst -> set(port driving a top output)
    for b, touch in netmap.items():
        drv = [(i, p) for (i, p, d) in touch if d == "output"]
        rdr = [(i, p) for (i, p, d) in touch if d == "input"]
        if not drv:
            continue
        si, sp = drv[0]
        if sp.lower() in GLOBAL_PORTS:
            continue
        if b in top_out_bits:
            displays.setdefault(si, set()).add(sp)
        for di, dp in rdr:
            if di == si or dp.lower() in GLOBAL_PORTS:
                continue
            edges.setdefault((si, sp, di, dp), 0)
            edges[(si, sp, di, dp)] += 1      # bit count (port width)

    # topological order: an instance that only drives (never reads another
    # instance's output) comes first. (linear chains; mesh_place.place() would
    # group for wider graphs.)
    consumes = {i: set() for i in insts}
    for (si, sp, di, dp) in edges:
        consumes[di].add(si)
    order, placed = [], set()
    while len(order) < len(insts):
        progressed = False
        for i in insts:
            if i not in placed and consumes[i] <= placed:
                order.append(i); placed.add(i); progressed = True
        if not progressed:                    # cycle (comb loop / feedback) — append rest
            for i in insts:
                if i not in placed:
                    order.append(i); placed.add(i)
            break

    node = {inst: (0, idx) for idx, inst in enumerate(order)}   # 1-row layout
    base = lambda idx: 0xF00 + idx * 0x40
    cores = []
    for idx, inst in enumerate(order):
        c = {"yx": list(node[inst]), "module": cells[inst]["type"],
             "instance": inst,
             "state_addr": hex(0x80000000 + base(idx)),
             "in_addr":    hex(0x80000000 + base(idx) + 0x10),
             "out_addr":   hex(0x80000000 + base(idx) + 0x20)}
        if inst in displays:
            sig = sorted(displays[inst])[0]
            c["display"] = {"signal": sig.upper(), "handle": 0}
        cores.append(c)

    edge_list = []
    for (si, sp, di, dp), w in edges.items():
        edge_list.append({"signal": sp.upper(), "width": w,
                          "producer": list(node[si]), "consumer": list(node[di])})

    out = {"design": args.top, "comment": "auto-derived by m3c2_partition.py (mesh_place)",
           "cores": cores, "edges": edge_list}
    with open(args.output, "w") as f:
        json.dump(out, f, indent=2)
    print(f"partitioned '{args.top}': {len(insts)} instances -> {len(order)} cores, "
          f"{len(edge_list)} cross-core edge(s)")
    for e in edge_list:
        print(f"  edge {e['signal']}[{e['width']}]  core{e['producer']} -> core{e['consumer']}")
    print(f"wrote map -> {args.output}")


if __name__ == "__main__":
    main()
