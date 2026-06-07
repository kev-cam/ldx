#!/usr/bin/env python3
# genmap.py <design.map>  ->  m3c0_map.h on stdout
# Reads the placement map and emits the per-core bindings the runtime needs:
# where state lives in BRAM, what drives the inputs, and the display expression.
import sys, json
m = json.load(open(sys.argv[1]))
c = m["cores"][0]                      # M3c.0: single core
print(f"// generated from {sys.argv[1]} by genmap.py — DO NOT EDIT")
print(f'#define MAP_STATE_ADDR {c["state_addr"]}u')
drives = " ".join(f"(in).{k} = {v}u;" for k, v in c.get("input_drives", {}).items())
print(f"#define MAP_INIT_INPUTS(in) do {{ {drives} }} while(0)")
print(f'#define MAP_DISPLAY_EXPR(o) ((o).{c["display"]["expr"]})')
print(f'#define MAP_DISP_HANDLE {c["display"]["handle"]}u')
