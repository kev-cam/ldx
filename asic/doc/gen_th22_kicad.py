#!/usr/bin/env python3
"""Emit a KiCad 6 .kicad_sch + .kicad_pro for the TH22 NCL C-element.

Lay out the 8-transistor cell across four columns — inputs, pull stacks
sharing node X, output inverter driving Y, weak keeper — using standard
Device:Q_NMOS_GDS and Device:Q_PMOS_GDS symbols from the KiCad stock lib.
Open with:  eeschema /tmp/th22/th22.kicad_sch

Coordinate system: KiCad schematics are in mm, origin top-left, Y down.
Grid = 2.54 mm (0.1"). All pin connection points land on grid.
"""

import os
import re
import uuid as _uuid

# ----- Extract two needed symbol defs from the stock Device library -----
DEVICE_LIB = "/usr/share/kicad/symbols/Device.kicad_sym"

def extract_symbol(libtext, name):
    """Pull the full `(symbol "NAME" ... )` block out of Device.kicad_sym."""
    # Match up to and including the paired closing paren (depth-tracked).
    i = libtext.index(f'(symbol "{name}"')
    depth = 0
    j = i
    while j < len(libtext):
        c = libtext[j]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return libtext[i : j + 1]
        j += 1
    raise RuntimeError(f"symbol {name} not closed")

with open(DEVICE_LIB) as f:
    LIB_TEXT = f.read()
SYM_NMOS = extract_symbol(LIB_TEXT, "Q_NMOS_GDS")
SYM_PMOS = extract_symbol(LIB_TEXT, "Q_PMOS_GDS")
# Prefix with Device: so lib_id references work.
SYM_NMOS = SYM_NMOS.replace('"Q_NMOS_GDS"', '"Device:Q_NMOS_GDS"', 1)
SYM_PMOS = SYM_PMOS.replace('"Q_PMOS_GDS"', '"Device:Q_PMOS_GDS"', 1)


def new_uuid():
    return str(_uuid.uuid4())


# ---------------------- Layout: grid in mm ----------------------
# Columns
X_IN    = 40.64    # input labels (A, B)
X_STACK = 88.90    # pull-up + pull-down stacks, node X
X_INV   = 134.62   # output inverter MPY/MNY
X_KEEP  = 177.80   # keeper MPK/MNK

# Rows for transistor centres (pin D at -5.08 from centre, S at +5.08)
Y_VDD   = 30.48   # top rail
Y_MPA   = 45.72
Y_MPB   = 66.04
Y_X     = 86.36   # node X — drain-to-drain junction
Y_MNB   = 93.98
Y_MNA   = 114.30
Y_VSS   = 134.62  # bottom rail
Y_MPY   = 55.88
Y_MNY   = 101.60
Y_Y     = 86.36   # output Y node, level with X
Y_MPK   = 55.88
Y_MNK   = 101.60


# ---------------------- Helpers ----------------------
def sym_instance(ref, lib_id, x, y, rot=0, value=""):
    """Emit a symbol instance."""
    u = new_uuid()
    # Properties are placed below/right of the symbol
    return f'''
  (symbol (lib_id "{lib_id}") (at {x} {y} {rot}) (unit 1)
    (in_bom yes) (on_board yes) (fields_autoplaced)
    (uuid {u})
    (property "Reference" "{ref}" (id 0) (at {x + 7.62} {y - 5.08} 0)
      (effects (font (size 1.27 1.27)) (justify left))
    )
    (property "Value" "{value}" (id 1) (at {x + 7.62} {y - 2.54} 0)
      (effects (font (size 1.27 1.27)) (justify left))
    )
    (property "Footprint" "" (id 2) (at {x} {y} 0)
      (effects (font (size 1.27 1.27)) hide)
    )
    (property "Datasheet" "" (id 3) (at {x} {y} 0)
      (effects (font (size 1.27 1.27)) hide)
    )
    (pin "1" (uuid {new_uuid()}))
    (pin "2" (uuid {new_uuid()}))
    (pin "3" (uuid {new_uuid()}))
  )'''


def wire(x1, y1, x2, y2):
    return f'''
  (wire (pts (xy {x1} {y1}) (xy {x2} {y2}))
    (stroke (width 0) (type default) (color 0 0 0 0))
    (uuid {new_uuid()})
  )'''


def label(text, x, y, angle=0):
    return f'''
  (label "{text}" (at {x} {y} {angle})
    (effects (font (size 1.27 1.27)) (justify left bottom))
    (uuid {new_uuid()})
  )'''


def power_sym(kind, x, y, rot=0):
    """Stock power symbol — VDD or GND. Uses power_pkg from stock power lib."""
    u = new_uuid()
    lib_id = f"power:{kind}"
    return f'''
  (symbol (lib_id "{lib_id}") (at {x} {y} {rot}) (unit 1)
    (in_bom yes) (on_board yes) (fields_autoplaced)
    (uuid {u})
    (property "Reference" "#PWR" (id 0) (at {x} {y - 3.81} 0)
      (effects (font (size 1.27 1.27)) hide)
    )
    (property "Value" "{kind}" (id 1) (at {x} {y - 3.81} 0)
      (effects (font (size 1.27 1.27)))
    )
    (property "Footprint" "" (id 2) (at {x} {y} 0)
      (effects (font (size 1.27 1.27)) hide)
    )
    (property "Datasheet" "" (id 3) (at {x} {y} 0)
      (effects (font (size 1.27 1.27)) hide)
    )
    (pin "1" (uuid {new_uuid()}))
  )'''


# Power symbol defs (minimal, just enough for VDD and GND to render)
POWER_SYMS = ""
with open(DEVICE_LIB.replace("Device", "power")) as f:
    pwr_lib = f.read()
for kname in ["VDD", "GND"]:
    POWER_SYMS += extract_symbol(pwr_lib, kname).replace(
        f'"{kname}"', f'"power:{kname}"', 1
    ) + "\n"


# ---------------------- Body of the schematic ----------------------
symbols = []

# Pull-up stack (PMOS): MPA at Y_MPA, MPB at Y_MPB. Both gate = X_STACK - 5.08
symbols.append(sym_instance("MPA", "Device:Q_PMOS_GDS", X_STACK, Y_MPA, 0, "sg13g2_pmos"))
symbols.append(sym_instance("MPB", "Device:Q_PMOS_GDS", X_STACK, Y_MPB, 0, "sg13g2_pmos"))

# Pull-down stack (NMOS): MNB, MNA
symbols.append(sym_instance("MNB", "Device:Q_NMOS_GDS", X_STACK, Y_MNB, 0, "sg13g2_nmos"))
symbols.append(sym_instance("MNA", "Device:Q_NMOS_GDS", X_STACK, Y_MNA, 0, "sg13g2_nmos"))

# Output inverter at X_INV
symbols.append(sym_instance("MPY", "Device:Q_PMOS_GDS", X_INV, Y_MPY, 0, "sg13g2_pmos"))
symbols.append(sym_instance("MNY", "Device:Q_NMOS_GDS", X_INV, Y_MNY, 0, "sg13g2_nmos"))

# Keeper at X_KEEP
symbols.append(sym_instance("MPK", "Device:Q_PMOS_GDS", X_KEEP, Y_MPK, 0, "sg13g2_pmos weak"))
symbols.append(sym_instance("MNK", "Device:Q_NMOS_GDS", X_KEEP, Y_MNK, 0, "sg13g2_nmos weak"))

# Power symbols at the top of each column
for X in (X_STACK, X_INV, X_KEEP):
    symbols.append(power_sym("VDD", X, Y_VDD))
    symbols.append(power_sym("GND", X, Y_VSS + 5.08, rot=0))

# ---------------------- Wires ----------------------
# PMOS pin geometry: pins D at (2.54, 5.08) (below body), S at (2.54, -5.08) (above body)
# When placed at (x, y), rotation 0:
#   G pin connection: (x - 5.08, y)     (with the 2.54 length already drawn)
#   D pin connection: (x + 2.54, y + 5.08)   [below]
#   S pin connection: (x + 2.54, y - 5.08)   [above]
# Both NMOS and PMOS follow same geometry.

def D_pin(x, y):  # drain connection point (lower)
    return (x + 2.54, y + 5.08)

def S_pin(x, y):  # source connection point (upper)
    return (x + 2.54, y - 5.08)

def G_pin(x, y):  # gate connection point (left)
    return (x - 5.08, y)

wires = []

# ---- Pull-up: VDD → MPA.S → MPA.D → MPB.S → MPB.D (=X) ----
# MPA.S up to VDD rail
wires.append(wire(*S_pin(X_STACK, Y_MPA), X_STACK + 2.54, Y_VDD))
# VDD symbol pin at (X_STACK, Y_VDD), we need to bridge (X_STACK, Y_VDD) to (X_STACK+2.54, Y_VDD)
wires.append(wire(X_STACK, Y_VDD, X_STACK + 2.54, Y_VDD))
# MPA.D down to MPB.S
wires.append(wire(*D_pin(X_STACK, Y_MPA), *S_pin(X_STACK, Y_MPB)))
# MPB.D down to X node
wires.append(wire(*D_pin(X_STACK, Y_MPB), X_STACK + 2.54, Y_X))

# ---- Pull-down: X → MNB.D → MNB.S → MNA.D → MNA.S → VSS ----
wires.append(wire(X_STACK + 2.54, Y_X, *D_pin(X_STACK, Y_MNB)))
wires.append(wire(*S_pin(X_STACK, Y_MNB), *D_pin(X_STACK, Y_MNA)))
wires.append(wire(*S_pin(X_STACK, Y_MNA), X_STACK + 2.54, Y_VSS + 5.08))
wires.append(wire(X_STACK + 2.54, Y_VSS + 5.08, X_STACK, Y_VSS + 5.08))

# ---- Input A to gates of MPA and MNA ----
for (x, y) in [G_pin(X_STACK, Y_MPA), G_pin(X_STACK, Y_MNA)]:
    wires.append(wire(x, y, X_IN, y))
# ---- Input B to gates of MPB and MNB ----
for (x, y) in [G_pin(X_STACK, Y_MPB), G_pin(X_STACK, Y_MNB)]:
    wires.append(wire(x, y, X_IN, y))

# ---- Output inverter ----
# MPY.S to VDD
wires.append(wire(*S_pin(X_INV, Y_MPY), X_INV + 2.54, Y_VDD))
wires.append(wire(X_INV, Y_VDD, X_INV + 2.54, Y_VDD))
# MPY.D to MNY.D — this is node Y
wires.append(wire(*D_pin(X_INV, Y_MPY), *D_pin(X_INV, Y_MNY)))
# MNY.S to VSS
wires.append(wire(*S_pin(X_INV, Y_MNY), X_INV + 2.54, Y_VSS + 5.08))
wires.append(wire(X_INV, Y_VSS + 5.08, X_INV + 2.54, Y_VSS + 5.08))
# Gate of MPY and MNY tied together to X. Route via busbar to the left.
# X node is at (X_STACK + 2.54, Y_X). Inverter gates are at G_pin(X_INV, Y_MPY/MNY).
gx_inv_top = G_pin(X_INV, Y_MPY)    # (X_INV - 5.08, Y_MPY)
gx_inv_bot = G_pin(X_INV, Y_MNY)
bus_x = X_INV - 10.16
wires.append(wire(gx_inv_top[0], gx_inv_top[1], bus_x, gx_inv_top[1]))
wires.append(wire(gx_inv_bot[0], gx_inv_bot[1], bus_x, gx_inv_bot[1]))
wires.append(wire(bus_x, gx_inv_top[1], bus_x, gx_inv_bot[1]))
wires.append(wire(bus_x, Y_X, X_STACK + 2.54, Y_X))

# ---- Keeper column MPK/MNK ----
wires.append(wire(*S_pin(X_KEEP, Y_MPK), X_KEEP + 2.54, Y_VDD))
wires.append(wire(X_KEEP, Y_VDD, X_KEEP + 2.54, Y_VDD))
wires.append(wire(*D_pin(X_KEEP, Y_MPK), *D_pin(X_KEEP, Y_MNK)))
wires.append(wire(*S_pin(X_KEEP, Y_MNK), X_KEEP + 2.54, Y_VSS + 5.08))
wires.append(wire(X_KEEP, Y_VSS + 5.08, X_KEEP + 2.54, Y_VSS + 5.08))
# Keeper gates fed by Y (drain junction of inverter)
gk_top = G_pin(X_KEEP, Y_MPK)
gk_bot = G_pin(X_KEEP, Y_MNK)
Y_bus_x = X_KEEP - 12.70
y_node  = (X_INV + 2.54, Y_Y)  # Y is the inverter drain junction
wires.append(wire(gk_top[0], gk_top[1], Y_bus_x, gk_top[1]))
wires.append(wire(gk_bot[0], gk_bot[1], Y_bus_x, gk_bot[1]))
wires.append(wire(Y_bus_x, gk_top[1], Y_bus_x, gk_bot[1]))
wires.append(wire(Y_bus_x, Y_Y, y_node[0], y_node[1]))

# Keeper drain junction back to X (the weak-feedback line) — use explicit wire
keeper_mid_y = (Y_MPK + Y_MNK) / 2   # just a visible mid-point
wires.append(wire(X_KEEP + 2.54, keeper_mid_y, X_KEEP + 2.54, Y_X))
wires.append(wire(X_KEEP + 2.54, Y_X, X_STACK + 2.54, Y_X))

# ---- Labels ----
labels_out = [
    label("A",   X_IN - 2.54, Y_MPA, 0),
    label("B",   X_IN - 2.54, Y_MPB, 0),
    label("A",   X_IN - 2.54, Y_MNA, 0),
    label("B",   X_IN - 2.54, Y_MNB, 0),
    label("X",   X_STACK + 4,  Y_X - 1, 0),
    label("Y",   X_INV   + 4,  Y_Y - 1, 0),
    label("N1",  X_STACK + 4,  (Y_MPA + Y_MPB) / 2, 0),
    label("N2",  X_STACK + 4,  (Y_MNB + Y_MNA) / 2, 0),
]

# ---------------------- Assemble file ----------------------
SCH = f'''(kicad_sch (version 20211123) (generator eeschema)

  (uuid {new_uuid()})

  (paper "A3")

  (title_block
    (title "TH22 — 2-input C-element (Muller gate)")
    (date "2026-04-16")
    (rev "1")
    (company "ldx NCL ASIC")
    (comment 1 "Pull-up MPA/MPB, Pull-down MNA/MNB, Output inverter MPY/MNY, Keeper MPK/MNK")
    (comment 2 "sg13g2 PSP103, 1.2V low-voltage CMOS")
  )

  (lib_symbols
    {SYM_NMOS}
    {SYM_PMOS}
    {POWER_SYMS}
  )
{''.join(wires)}
{''.join(labels_out)}
{''.join(symbols)}

  (sheet_instances
    (path "/" (page "1"))
  )

  (symbol_instances
  )
)
'''

# ---------------------- Write project + schematic ----------------------
OUT = "/tmp/th22"
os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "th22.kicad_sch"), "w") as f:
    f.write(SCH)

# Minimal .kicad_pro so eeschema will open nicely
PRO = '''{
  "board": {},
  "boards": [],
  "cvpcb": {},
  "libraries": {},
  "meta": {"filename": "th22.kicad_pro", "version": 1},
  "net_settings": {"classes": [{"name": "Default"}]},
  "pcbnew": {},
  "schematic": {
    "meta": {"version": 1}
  },
  "sheets": [["th22.kicad_sch", ""]],
  "text_variables": {}
}
'''
with open(os.path.join(OUT, "th22.kicad_pro"), "w") as f:
    f.write(PRO)

print(f"Wrote {OUT}/th22.kicad_sch and {OUT}/th22.kicad_pro")
print(f"Open with: eeschema {OUT}/th22.kicad_sch")
