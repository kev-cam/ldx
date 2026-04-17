#!/usr/bin/env python3
"""TH22 2-input C-element / Muller gate — schematic render with explicit coords."""

import schemdraw
import schemdraw.elements as e

d = schemdraw.Drawing(show=False, canvas="matplotlib")
d.config(fontsize=10, lw=1.2, unit=2.0)

# Lay out four columns: A/B inputs (col 0), pull stacks + X (col 1),
# output inverter (col 2), keeper (col 3).

X_INPUT = 0
X_STACK = 6
X_INV   = 11
X_KEEP  = 16

Y_VDD   = 16
Y_MPA   = 13
Y_MPB   = 10
Y_X     = 8
Y_MNB   = 6
Y_MNA   = 3
Y_VSS   = 0

# === VDD rail ===
d += e.Line().at((X_INPUT - 2, Y_VDD)).to((X_KEEP + 2, Y_VDD))
d += e.Label().at((X_INPUT - 2, Y_VDD + 0.3)).label("VDD")

# === VSS rail ===
d += e.Line().at((X_INPUT - 2, Y_VSS)).to((X_KEEP + 2, Y_VSS))
d += e.Label().at((X_INPUT - 2, Y_VSS - 0.3)).label("VSS")

# === Pull-up stack — PMOS MPA and MPB in series ===
mpa = d.add(e.PFet().at((X_STACK, Y_MPA)).flip())
d += e.Line().at((X_STACK, Y_VDD)).to(mpa.source)
d += e.Label().at((X_STACK + 0.5, Y_MPA + 0.5)).label("MPA")

mpb = d.add(e.PFet().at((X_STACK, Y_MPB)).flip())
d += e.Line().at(mpa.drain).to(mpb.source)
d += e.Label().at((X_STACK + 0.5, Y_MPB + 0.5)).label("MPB")
d += e.Dot().at((X_STACK, (Y_MPA + Y_MPB) / 2))
d += e.Label().at((X_STACK + 0.6, (Y_MPA + Y_MPB) / 2)).label("N1")

# === Node X (shared drain of MPB and MNB) ===
d += e.Dot().at((X_STACK, Y_X))
d += e.Label().at((X_STACK - 0.6, Y_X + 0.3)).label("X")
d += e.Line().at(mpb.drain).to((X_STACK, Y_X))

# === Pull-down stack — NMOS MNB and MNA in series ===
mnb = d.add(e.NFet().at((X_STACK, Y_MNB)))
d += e.Line().at((X_STACK, Y_X)).to(mnb.drain)
d += e.Label().at((X_STACK + 0.5, Y_MNB + 0.5)).label("MNB")

mna = d.add(e.NFet().at((X_STACK, Y_MNA)))
d += e.Line().at(mnb.source).to(mna.drain)
d += e.Label().at((X_STACK + 0.5, Y_MNA + 0.5)).label("MNA")
d += e.Dot().at((X_STACK, (Y_MNB + Y_MNA) / 2))
d += e.Label().at((X_STACK + 0.6, (Y_MNB + Y_MNA) / 2)).label("N2")

d += e.Line().at(mna.source).to((X_STACK, Y_VSS))

# === Input A & B to gate pins ===
# A goes to MPA and MNA; B to MPB and MNB.
for fet, label in [(mpa, "A"), (mpb, "B"), (mnb, "B"), (mna, "A")]:
    d += e.Line().at(fet.gate).to((X_INPUT, fet.gate[1]))
    d += e.Dot(open=True).at((X_INPUT, fet.gate[1]))
    d += e.Label().at((X_INPUT - 0.5, fet.gate[1])).label(label)

# === Output inverter MPY/MNY ===
mpy = d.add(e.PFet().at((X_INV, Y_MPB)).flip())
mny = d.add(e.NFet().at((X_INV, Y_MNB)))
d += e.Label().at((X_INV + 0.5, Y_MPB + 0.5)).label("MPY")
d += e.Label().at((X_INV + 0.5, Y_MNB + 0.5)).label("MNY")
d += e.Line().at((X_INV, Y_VDD)).to(mpy.source)
d += e.Line().at(mpy.drain).to(mny.drain)
d += e.Line().at(mny.source).to((X_INV, Y_VSS))

# Y node is at the drain junction
Y_NODE = (X_INV, (Y_MPB + Y_MNB) / 2)
d += e.Dot().at(Y_NODE)
d += e.Label().at((X_INV - 0.4, Y_NODE[1] + 0.3)).label("Y")
d += e.Line().at(Y_NODE).right().length(2)
d += e.Dot(open=True).at((X_INV + 2, Y_NODE[1]))
d += e.Label().at((X_INV + 2.5, Y_NODE[1])).label("→ out")

# Gates of MPY and MNY are tied together to X via a bus
d += e.Line().at(mpy.gate).to((mpy.gate[0] - 1, mpy.gate[1]))
d += e.Line().at(mny.gate).to((mny.gate[0] - 1, mny.gate[1]))
d += e.Line().at((mpy.gate[0] - 1, mpy.gate[1])).to((mpy.gate[0] - 1, mny.gate[1]))
d += e.Line().at((mpy.gate[0] - 1, (mpy.gate[1] + mny.gate[1]) / 2)).to(
    (X_STACK, (mpy.gate[1] + mny.gate[1]) / 2))

# === Keeper MPK/MNK — weak feedback from Y → X ===
mpk = d.add(e.PFet().at((X_KEEP, Y_MPB)).flip())
mnk = d.add(e.NFet().at((X_KEEP, Y_MNB)))
d += e.Label().at((X_KEEP + 0.6, Y_MPB + 0.5)).label("MPK\n(weak)")
d += e.Label().at((X_KEEP + 0.6, Y_MNB + 0.5)).label("MNK\n(weak)")
d += e.Line().at((X_KEEP, Y_VDD)).to(mpk.source)
d += e.Line().at(mpk.drain).to(mnk.drain)
d += e.Line().at(mnk.source).to((X_KEEP, Y_VSS))

# Keeper gates fed from Y
d += e.Line().at(mpk.gate).to((mpk.gate[0] - 1, mpk.gate[1]))
d += e.Line().at(mnk.gate).to((mnk.gate[0] - 1, mnk.gate[1]))
d += e.Line().at((mpk.gate[0] - 1, mpk.gate[1])).to((mpk.gate[0] - 1, mnk.gate[1]))
# Bus from Y to keeper gate bus (crosses over)
d += e.Line(ls="--").at(Y_NODE).to((X_KEEP - 1, Y_NODE[1]))
d += e.Line(ls="--").at((X_KEEP - 1, Y_NODE[1])).to(
    (mpk.gate[0] - 1, (mpk.gate[1] + mnk.gate[1]) / 2))

# Keeper drain (shared) feeds back to X via a long dashed line
KEEP_MID = (X_KEEP, (Y_MPB + Y_MNB) / 2)
d += e.Line(ls=":").at(KEEP_MID).to((X_STACK, Y_X))
d += e.Label().at((X_STACK + 3, Y_X + 0.5)).label("weak keeper feedback")

# Title
d += e.Label().at(((X_INPUT + X_KEEP) / 2, Y_VDD + 2)).label(
    "TH22 — NCL 2-input C-element (Muller gate)\n"
    "sg13g2 1.2 V, 10 transistors")

d.save("/tmp/th22_schematic.png", dpi=150)
d.save("/tmp/th22_schematic.svg")
print("Wrote /tmp/th22_schematic.png and /tmp/th22_schematic.svg")
