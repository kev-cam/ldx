#!/usr/bin/env python3
# Generate the log-log scaling SVG: sim throughput (DUT cycles/s) vs design size (cells).
# Measured points = solid dots; model lines = dashed; capacity/IC markers on the x-axis.
import math

W, H = 900, 640
ML, MR, MT, MB = 78, 24, 40, 150
PW, PH = W-ML-MR, H-MT-MB
X0, X1 = 1.0, 9.0     # log10 cells: 10 .. 1e9
Y0, Y1 = 2.0, 9.3     # log10 cyc/s: 1e2 .. 2e9

def xp(cells): return ML + (math.log10(cells)-X0)/(X1-X0)*PW
def yp(rate):  return MT + PH - (math.log10(rate)-Y0)/(Y1-Y0)*PH

CPU   = "#d97706"   # amber
ARR   = "#2563eb"   # blue
PROJ  = "#9333ea"   # purple
GRAY  = "#888888"

s = []
s.append(f'<svg viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" font-family="-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif" font-size="13">')
s.append(f'<style>text{{fill:currentColor}} .mut{{opacity:.65}} .tick{{stroke:currentColor;opacity:.15}} .axis{{stroke:currentColor;opacity:.5}}</style>')

# win band: where the array model sits above the CPU model (5e3 .. 5e5 cells)
s.append(f'<rect x="{xp(5e3):.1f}" y="{MT}" width="{xp(5e5)-xp(5e3):.1f}" height="{PH}" fill="{ARR}" opacity="0.07"/>')

# gridlines + tick labels
for e in range(int(X0), int(X1)+1):
    x = xp(10**e)
    s.append(f'<line class="tick" x1="{x:.1f}" y1="{MT}" x2="{x:.1f}" y2="{MT+PH}"/>')
    s.append(f'<text x="{x:.1f}" y="{MT+PH+18}" text-anchor="middle" class="mut">10<tspan dy="-4" font-size="9">{e}</tspan></text>')
for e in range(int(Y0), 10):
    y = yp(10**e)
    s.append(f'<line class="tick" x1="{ML}" y1="{y:.1f}" x2="{ML+PW}" y2="{y:.1f}"/>')
    s.append(f'<text x="{ML-8}" y="{y+4:.1f}" text-anchor="end" class="mut">10<tspan dy="-4" font-size="9">{e}</tspan></text>')
s.append(f'<rect x="{ML}" y="{MT}" width="{PW}" height="{PH}" fill="none" class="axis"/>')
s.append(f'<text x="{ML+PW/2}" y="{MT+PH+40}" text-anchor="middle">design size (synthesized cells, log)</text>')
s.append(f'<text x="20" y="{MT+PH/2}" text-anchor="middle" transform="rotate(-90 20 {MT+PH/2})">simulated throughput (DUT cycles/s, log)</text>')

def polyline(pts, color, dash, width=2.2):
    p = " ".join(f"{xp(c):.1f},{yp(r):.1f}" for c, r in pts)
    d = f' stroke-dasharray="{dash}"' if dash else ""
    s.append(f'<polyline points="{p}" fill="none" stroke="{color}" stroke-width="{width}"{d}/>')

# --- model lines (all dashed = modeled) ---
# CPU, one x86 thread, compiled model: rate = min(3e8, 3e9/N) in cache; 10x cliff past ~1e6 cells
cpu = []
for lg in [1.0,1.3,2,2.5,3,3.5,4,4.5,5,5.5,6.0]:
    n = 10**lg; cpu.append((n, min(3e8, 3e9/n)))
cpu += [(1e6+1, 3e8/1e6), (3e6, 1e2)]
polyline(cpu, CPU, "7 4")
# ZCU104 64-core array, partitioned design: 64 x 250M cell-cyc/s x 0.5 eff = 8e9/N, capacity ~64k cells
polyline([(6.4e3, 8e9/6.4e3), (6.4e4, 8e9/6.4e4)], ARR, "7 4")
s.append(f'<line x1="{xp(6.4e4):.1f}" y1="{yp(8e9/6.4e4):.1f}" x2="{xp(6.4e4):.1f}" y2="{yp(8e9/6.4e4)+26:.1f}" stroke="{ARR}" stroke-width="2.2" stroke-dasharray="2 3"/>')
# D5005-class projection: ~450 cores x 250M x 1.5 clk x 0.5 eff ~ 2e10/N, capacity ~0.5M cells
polyline([(5e4, 2e10/5e4), (5e5, 2e10/5e5)], PROJ, "3 5")
s.append(f'<line x1="{xp(5e5):.1f}" y1="{yp(2e10/5e5):.1f}" x2="{xp(5e5):.1f}" y2="{yp(2e10/5e5)+26:.1f}" stroke="{PROJ}" stroke-width="2" stroke-dasharray="2 3"/>')

# --- measured points ---
def pt(cells, rate, color, label, dx=8, dy=4, open_=False, anchor="start"):
    fill = "none" if open_ else color
    s.append(f'<circle cx="{xp(cells):.1f}" cy="{yp(rate):.1f}" r="5" fill="{fill}" stroke="{color}" stroke-width="2"/>')
    s.append(f'<text x="{xp(cells)+dx:.1f}" y="{yp(rate)+dy:.1f}" font-size="11.5" text-anchor="{anchor}">{label}</text>')

pt(20,   2.58e8, CPU, "xorshift · x86 1-thread")
pt(120,  2.37e7, CPU, "bet FIFO · x86")
pt(120,  7.35e6, CPU, "bet FIFO · A53 (on ZCU104)")
pt(120,  6.76e5, CPU, "bet FIFO · Verilator+TB x86")
pt(20,   9.96e6, ARR, "xorshift · 1 array core", dx=10)
pt(20,   6.37e8, ARR, "xorshift · 64 independent sims (aggregate)", open_=True, dx=10)
pt(4000, 1.23e5, ARR, "SHA-256 · 1 array core (~4k cells est.)")

# --- capacity / IC markers along the bottom ---
def marker(cells, lines, color=GRAY, row=0):
    x = xp(cells)
    s.append(f'<line x1="{x:.1f}" y1="{MT}" x2="{x:.1f}" y2="{MT+PH}" stroke="{color}" stroke-width="1.2" stroke-dasharray="2 4" opacity="0.55"/>')
    base = MT+PH+56+row*44
    for i, t in enumerate(lines):
        s.append(f'<text x="{x:.1f}" y="{base+i*13}" text-anchor="middle" font-size="10.5" class="mut">{t}</text>')

marker(6.4e4, ["ZCU104 array full", "~64k cells ≈ 0.06%", "of a 100M-gate IC"], ARR, row=0)
marker(5e5,  ["D5005 array full", "~0.5M cells ≈ 0.5% of IC"], PROJ, row=1)
marker(1e6,  ["≈ one x86 LLC", "(CPU cache cliff)"], CPU, row=0)
marker(1e8,  ["full 100M-gate IC", "(emulator / multi-FPGA territory)"], row=0)

# crossover annotation
s.append(f'<text x="{xp(5e3):.1f}" y="{MT-10}" font-size="11.5" fill="{ARR}">crossover: design partitions across ≥64 cores → array wins</text>')
s.append(f'<line x1="{xp(5e3):.1f}" y1="{MT}" x2="{xp(5e3):.1f}" y2="{MT+PH}" stroke="{ARR}" stroke-width="1.4" stroke-dasharray="6 3" opacity="0.6"/>')

# legend
lx, ly = ML+PW-278, MT+26
s.append(f'<rect x="{lx-10}" y="{ly-16}" width="278" height="92" fill="none" class="axis" rx="6"/>')
s.append(f'<line x1="{lx}" y1="{ly}" x2="{lx+30}" y2="{ly}" stroke="{CPU}" stroke-width="2.2" stroke-dasharray="7 4"/><text x="{lx+38}" y="{ly+4}" font-size="11.5">CPU, 1 thread, compiled model (model)</text>')
s.append(f'<line x1="{lx}" y1="{ly+20}" x2="{lx+30}" y2="{ly+20}" stroke="{ARR}" stroke-width="2.2" stroke-dasharray="7 4"/><text x="{lx+38}" y="{ly+24}" font-size="11.5">ZCU104 8×8 array, partitioned (model)</text>')
s.append(f'<line x1="{lx}" y1="{ly+40}" x2="{lx+30}" y2="{ly+40}" stroke="{PROJ}" stroke-width="2" stroke-dasharray="3 5"/><text x="{lx+38}" y="{ly+44}" font-size="11.5">D5005-class array (projection)</text>')
s.append(f'<circle cx="{lx+15}" cy="{ly+60}" r="5" fill="currentColor" opacity=".7"/><text x="{lx+38}" y="{ly+64}" font-size="11.5">measured run (○ = aggregate of 64 sims)</text>')

s.append('</svg>')
print("\n".join(s))
