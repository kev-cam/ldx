#!/usr/bin/env python3
# Generate the log-log scaling SVG: simulated clocks/s vs design size (gates).
# Solid dots and solid lines = measured; dashed = speculation / hypothetical.
import math

W, H = 900, 730
ML, MR, MT, MB = 78, 24, 40, 240
PW, PH = W-ML-MR, H-MT-MB
X0, X1 = 1.0, 9.0     # log10 gates: 10 .. 1e9
Y0, Y1 = 2.0, 9.3     # log10 clocks/s

def xp(cells): return ML + (math.log10(cells)-X0)/(X1-X0)*PW
def yp(rate):  return MT + PH - (math.log10(rate)-Y0)/(Y1-Y0)*PH

CPU   = "#d97706"   # amber  - x86 / Verilator
ARR   = "#2563eb"   # blue   - ZCU104
BUILT = "#0d9488"   # teal   - VU47P (AWS F2)
PROJ  = "#9333ea"   # purple - Agilex 27 (speculation)
SPIN  = "#db2777"   # pink   - SpiNNaker2 (hypothetical)
WSE   = "#64748b"   # slate  - Cerebras (hypothetical)
GRAY  = "#888888"

G = 7.7e3             # gates per SHA-mesh cell (yosys, generic 2-input gates + flops, inverters not counted)
def gates(ny, nx): return ny*nx*G

s = []
s.append(f'<svg viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif" font-size="13">')
s.append('<style>text{fill:currentColor} .mut{opacity:.65} .tick{stroke:currentColor;opacity:.15} .axis{stroke:currentColor;opacity:.5}</style>')

# band: sizes where the measured engine arrays sit above the best measured Verilator run
s.append(f'<rect x="{xp(1e6):.1f}" y="{MT}" width="{xp(gates(56,56))-xp(1e6):.1f}" height="{PH}" fill="{BUILT}" opacity="0.07"/>')

for e in range(int(X0), int(X1)+1):
    x = xp(10**e)
    s.append(f'<line class="tick" x1="{x:.1f}" y1="{MT}" x2="{x:.1f}" y2="{MT+PH}"/>')
    s.append(f'<text x="{x:.1f}" y="{MT+PH+18}" text-anchor="middle" class="mut">10<tspan dy="-4" font-size="9">{e}</tspan></text>')
for e in range(int(Y0), 10):
    y = yp(10**e)
    s.append(f'<line class="tick" x1="{ML}" y1="{y:.1f}" x2="{ML+PW}" y2="{y:.1f}"/>')
    s.append(f'<text x="{ML-8}" y="{y+4:.1f}" text-anchor="end" class="mut">10<tspan dy="-4" font-size="9">{e}</tspan></text>')
s.append(f'<rect x="{ML}" y="{MT}" width="{PW}" height="{PH}" fill="none" class="axis"/>')
s.append(f'<text x="{ML+PW/2}" y="{MT+PH+40}" text-anchor="middle">design size (gates, log)</text>')
s.append(f'<text x="20" y="{MT+PH/2}" text-anchor="middle" transform="rotate(-90 20 {MT+PH/2})">simulated clocks per second (log)</text>')

def polyline(pts, color, dash, width=2.2):
    p = " ".join(f"{xp(c):.1f},{yp(r):.1f}" for c, r in pts)
    d = f' stroke-dasharray="{dash}"' if dash else ""
    s.append(f'<polyline points="{p}" fill="none" stroke="{color}" stroke-width="{width}"{d}/>')
def pt(cells, rate, color, label="", dx=8, dy=4, open_=False, anchor="start", r=5):
    fill = "none" if open_ else color
    s.append(f'<circle cx="{xp(cells):.1f}" cy="{yp(rate):.1f}" r="{r}" fill="{fill}" stroke="{color}" stroke-width="2"/>')
    if label: s.append(f'<text x="{xp(cells)+dx:.1f}" y="{yp(rate)+dy:.1f}" font-size="11.5" text-anchor="{anchor}">{label}</text>')
def drop(cells, rate, color):
    s.append(f'<line x1="{xp(cells):.1f}" y1="{yp(rate):.1f}" x2="{xp(cells):.1f}" y2="{yp(rate)+26:.1f}" stroke="{color}" stroke-width="2.2" stroke-dasharray="2 3"/>')

# --- hypothetical machines (arithmetic only; nothing was run on either) ---
# Per-core basis: our plain RISC core, measured 16,211 clocks/s x 64 mesh cells = 1.04M mesh-cell evaluations/s.
RISC_CORE = 16211 * 64 * G                    # gate-evaluations/s of one plain soft core at 125 MHz
# SpiNNaker2, one 48-chip board = 7,296 Arm M4F cores: ASSUME 3x our soft core each, 0.5 efficiency, and a
# 300k clocks/s ceiling from per-clock synchronisation over its packet network.
SP = 7296 * RISC_CORE * 3 * 0.5; SP_CAP = 3e5
polyline([(5e5, SP_CAP), (SP/SP_CAP, SP_CAP), (1e9, SP/1e9)], SPIN, "2 5", 2)
# Cerebras WSE-3, 900,000 cores: ASSUME each equals our soft core, 0.5 efficiency, 1M clocks/s ceiling.
polyline([(5e5, 1e6), (1e9, 1e6)], WSE, "2 5", 2)

# --- Agilex 27 (Agilex 2X; samples expected 2H 2027) - SPECULATION, no silicon ---
# A27F180: 5,683,872 ALMs. Two thirds of them at an ASSUMED 15k ALMs per node (RISC core + wide-word engine; the
# node measures ~18k LUTs on UltraScale+) -> ~250 nodes x 64 mesh cells; ASSUMED 1.5x the measured clock rate.
AG_NODES = 250; AG_CAP = AG_NODES*64*G; AG_RATE = 5.9e5*1.5
polyline([(64*G, AG_RATE), (AG_CAP, AG_RATE)], PROJ, "3 5")
drop(AG_CAP, AG_RATE, PROJ)

# --- measured: Verilator on a 16-core Threadripper PRO 5955WX, SHA-mesh ---
V1 = [(gates(20,20), 56.4e3), (gates(24,24), 31.9e3), (gates(40,40), 8.2e3), (gates(56,56), 4.2e3), (gates(80,80), 1.8e3)]
VB = [(gates(20,20), 209e3), (gates(24,24), 129.8e3), (gates(40,40), 68.8e3), (gates(56,56), 29.8e3), (gates(80,80), 12.2e3)]
polyline(V1, CPU, "", 1.6); polyline(VB, CPU, "", 2.4)
for c, r in V1: pt(c, r, CPU, r=3, open_=True)
for c, r in VB: pt(c, r, CPU, r=3.5)
s.append(f'<text x="{xp(V1[0][0])-8:.1f}" y="{yp(V1[0][1])+4:.1f}" font-size="11.5" text-anchor="end">Verilator, 1 thread</text>')
s.append(f'<text x="{xp(VB[0][0])-8:.1f}" y="{yp(VB[0][1])+4:.1f}" font-size="11.5" text-anchor="end">Verilator, best of 1–16 threads</text>')

# --- measured: engine arrays on silicon (flat: the rate is set by the 219-clock microprogram, not by the size) ---
Z, F = gates(24,24), gates(56,56)
polyline([(64*G, 591455), (Z, 591455)], ARR, "", 1.4)
polyline([(Z, 569882), (F, 569882)], BUILT, "", 1.4)
def lead(cells, rate, color, up):
    s.append(f'<line x1="{xp(cells):.1f}" y1="{yp(rate)-6:.1f}" x2="{xp(cells):.1f}" y2="{yp(rate)-up+5:.1f}" stroke="{color}" stroke-width="1"/>')
lead(Z, 591455, ARR, 34); lead(F, 569882, BUILT, 52)
pt(Z, 591455, ARR, "ZCU104, 3×3 nodes + engines · 591k", dx=4, dy=-34, anchor="end")
pt(F, 569882, BUILT, "AWS F2 VU47P, 7×7 nodes + engines · 570k", dx=4, dy=-52, anchor="end")
pt(F, 25625, BUILT); pt(Z, 25678, ARR, "both arrays, RISC core + logic extension · 25.6k", dx=-10, dy=6, anchor="end")
pt(Z, 16211, ARR, "ZCU104, plain RISC core · 16.2k", dx=-8, dy=17, anchor="end")

# --- earlier small-design measurements (unchanged) ---
pt(20,   2.58e8, CPU, "xorshift · x86 1-thread")
pt(120,  2.37e7, CPU, "bet FIFO · x86")
pt(120,  7.35e6, CPU, "bet FIFO · A53 (on ZCU104)")
pt(120,  6.76e5, CPU, "bet FIFO · Verilator+TB x86")
pt(20,   9.96e6, ARR, "xorshift · 1 array core", dx=10, dy=-6)
pt(20,   6.37e8, ARR, "xorshift · 64 independent sims (aggregate)", open_=True, dx=10)
pt(4000, 1.23e5, ARR, "SHA-256 · 1 array core (~4k gates est.)")

# --- capacity markers along the bottom ---
def marker(cells, lines, color=GRAY, row=0):
    x = xp(cells)
    s.append(f'<line x1="{x:.1f}" y1="{MT}" x2="{x:.1f}" y2="{MT+PH}" stroke="{color}" stroke-width="1.2" stroke-dasharray="2 4" opacity="0.55"/>')
    base = MT+PH+58+row*44
    for i, t in enumerate(lines):
        s.append(f'<text x="{x:.1f}" y="{base+i*13}" text-anchor="middle" font-size="10.5" class="mut">{t}</text>')
marker(1e8,  ["a 100M-gate IC"], row=0)
marker(Z,    ["ZCU104 full: 9 nodes, 576 mesh cells", "≈ 4.4M gates (measured)"], ARR, row=1)
marker(F,    ["VU47P full: 49 nodes, 3,136 mesh cells", "≈ 24M gates (measured)"], BUILT, row=2)
marker(AG_CAP, ["Agilex 27 largest: ~250 nodes", "≈ 120M gates (speculation)"], PROJ, row=3)

s.append(f'<text x="{xp(1e6)+4:.1f}" y="{MT-10}" font-size="11.5" fill="{BUILT}">engine array above Verilator on all 16 cores</text>')

# legend
lx, ly = ML+24, MT+PH-124
s.append(f'<rect x="{lx-10}" y="{ly-16}" width="302" height="132" fill="none" class="axis" rx="6"/>')
def leg(i, color, dash, text, w=2.2):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    s.append(f'<line x1="{lx}" y1="{ly+20*i}" x2="{lx+30}" y2="{ly+20*i}" stroke="{color}" stroke-width="{w}"{d}/><text x="{lx+38}" y="{ly+20*i+4}" font-size="11.5">{text}</text>')
s.append(f'<circle cx="{lx+15}" cy="{ly}" r="5" fill="currentColor" opacity=".7"/><text x="{lx+38}" y="{ly+4}" font-size="11.5">measured, output checked (solid lines too)</text>')
leg(1, CPU, "", "Verilator on x86, measured")
leg(2, BUILT, "", "engine arrays on FPGA, measured", 1.4)
leg(3, PROJ, "3 5", "Agilex 27 engine array, speculation")
leg(4, SPIN, "2 5", "SpiNNaker2 board, hypothetical", 2)
leg(5, WSE, "2 5", "Cerebras WSE-3, hypothetical", 2)

s.append('</svg>')
print("\n".join(s))
