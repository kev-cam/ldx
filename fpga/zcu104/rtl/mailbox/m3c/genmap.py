#!/usr/bin/env python3
# genmap.py <design.map> -> header on stdout.
# No edges  -> M3c.0 single-core bindings.
# With edges -> M3c.1 cross-core placement (producer/consumer state addrs, edge, display).
import sys, json
m = json.load(open(sys.argv[1]))
cores = m["cores"]; edges = m.get("edges", [])
print(f"// generated from {sys.argv[1]} by genmap.py — DO NOT EDIT")
if not edges:
    c = cores[0]
    print(f'#define MAP_STATE_ADDR {c["state_addr"]}u')
    drives = " ".join(f"(in).{k} = {v}u;" for k, v in c.get("input_drives", {}).items())
    print(f"#define MAP_INIT_INPUTS(in) do {{ {drives} }} while(0)")
    print(f'#define MAP_DISPLAY_EXPR(o) ((o).{c["display"]["expr"]})')
    print(f'#define MAP_DISP_HANDLE {c["display"]["handle"]}u')
else:
    e = edges[0]
    at = lambda yx: next(c for c in cores if c["yx"] == yx)
    pc, cc = at(e["producer"]), at(e["consumer"])
    cy, cx = e["consumer"]
    print(f'#define P_STATE_ADDR {pc["state_addr"]}u')
    print(f'#define P_IN_ADDR {pc["in_addr"]}u')
    print(f'#define P_OUT_ADDR {pc["out_addr"]}u')
    print(f'#define C_STATE_ADDR {cc["state_addr"]}u')
    print(f'#define C_IN_ADDR {cc["in_addr"]}u')
    print(f'#define C_OUT_ADDR {cc["out_addr"]}u')
    print(f'#define EDGE_SIGNAL "{e["signal"]}"')
    print(f'#define CONS_Y {cy}u')
    print(f'#define CONS_X {cx}u')
    d = cc.get("display")
    if d:
        print(f'#define DISP_SIGNAL "{d["signal"]}"')
        print(f'#define DISP_HANDLE {d["handle"]}u')
