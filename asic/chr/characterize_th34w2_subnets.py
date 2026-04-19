#!/usr/bin/env python3
"""Characterise TH34W2 sub-networks — weighted 3-of-4 threshold gate.

TH34W2 fires when 2·A + B + C + D ≥ 3, so input A has weight 2.
Pull-down branches: (A·B) || (A·C) || (A·D) || (B·C·D).
Pull-up: 4 PMOS in series (strict NCL reset — fires only when all LOW).

Sub-networks characterised:
  pull-up : I_pu(V_X, V_A, V_B, V_C, V_D)
  pull-down: I_pd(V_X, V_A, V_B, V_C, V_D)
Inverter + keeper are identical to TH22's (same MPY/MNY/MPK/MNK sizing),
so we reuse those from /tmp/th22_char/tables.npz.

Grid: V_X at 13 points, each of V_A/V_B/V_C/V_D at 5 points. That's
5^4 = 625 points × 13 V_X sub-sweeps × 2 networks.
"""

import csv
import os
import subprocess
import sys
import numpy as np

XYCE = "/usr/local/src/Xyce-8/xyce-build/src/Xyce"
PLUGIN = "/usr/local/src/kestrel/sim/psp103_sg13g2.so"
MODELS = "/tmp/sg13g2_models.lib"

VDD_LIST = [0.9, 1.05, 1.2, 1.35, 1.5]   # legacy; unused by PWL path
V_MIN = -0.2
V_MAX = 1.5
VDD_MIN = 0.9
VDD_MAX = 1.5
T_SIM = 40.0
N_VX_CYCLES = 5
T_SAMPLE = 0.05
V_GATE = np.linspace(0.0, 1.5, 5)

WORK = "/tmp/th34w2_char"
os.makedirs(WORK, exist_ok=True)


def vx_pwl(t_end: float) -> str:
    half = t_end / (2 * N_VX_CYCLES)
    pts = [(0.0, V_MIN)]
    up = True
    t = 0.0
    for _ in range(2 * N_VX_CYCLES):
        t += half
        pts.append((t, V_MAX if up else V_MIN))
        up = not up
    body = "\n".join(f"+ {p[0]:.4f}n {p[1]}" for p in pts)
    return "PWL\n" + body


def vdd_pwl(t_end: float) -> str:
    half = t_end / 2.0
    return (f"PWL\n+ 0n {VDD_MIN}\n+ {half:.3f}n {VDD_MAX}\n"
            f"+ {t_end:.3f}n {VDD_MIN}")


def run_xyce(sp_path):
    subprocess.run([XYCE, "-plugin", PLUGIN, sp_path],
                   capture_output=True, text=True, check=False, cwd=WORK)
    csv_path = sp_path + ".csv"
    if not os.path.exists(csv_path):
        raise RuntimeError(f"Xyce failed on {sp_path}")
    rows = list(csv.reader(open(csv_path)))
    hdr = [h.strip().upper() for h in rows[0]]
    data = np.array([[float(x) for x in row] for row in rows[1:]])
    return hdr, data


def sweep_pullup():
    """I_pu scatter via nested PWL.
    Cols: (VDD, V_X, V_A, V_B, V_C, V_D, I)."""
    samples = []
    for idv, vd in enumerate(V_GATE):
        for ic, vc in enumerate(V_GATE):
            for ib, vb in enumerate(V_GATE):
                for ia, va in enumerate(V_GATE):
                    print(f"  pu A={va:.2f} B={vb:.2f} C={vc:.2f} D={vd:.2f}")
                    sp = f"""* pullup TH34W2 A={va} B={vb} C={vc} D={vd}
.include "{MODELS}"
VVDD VDD 0 {vdd_pwl(T_SIM)}
VA   A   0 {va}
VB   B   0 {vb}
VC   C   0 {vc}
VD   D   0 {vd}
VX   X   0 {vx_pwl(T_SIM)}
MPA  P1 A VDD VDD sg13g2_pmos W=1.2u L=0.13u
MPB  P2 B P1  VDD sg13g2_pmos W=1.2u L=0.13u
MPC  P3 C P2  VDD sg13g2_pmos W=1.2u L=0.13u
MPD  X  D P3  VDD sg13g2_pmos W=1.2u L=0.13u
.tran {T_SAMPLE}n {T_SIM}n
.print tran format=csv time v(VDD) v(X) i(VX)
.end
"""
                    path = f"{WORK}/pu_{ia}_{ib}_{ic}_{idv}.sp"
                    open(path, "w").write(sp)
                    hdr, d = run_xyce(path)
                    col_vdd = hdr.index("V(VDD)")
                    col_vx  = hdr.index("V(X)")
                    col_i   = hdr.index("I(VX)")
                    for row in range(d.shape[0]):
                        samples.append((float(d[row, col_vdd]),
                                        float(d[row, col_vx]),
                                        va, vb, vc, vd,
                                        float(d[row, col_i])))
    return np.array(samples)


def sweep_pulldown():
    """I_pd scatter — 4-branch weighted A·B || A·C || A·D || B·C·D.
    Cols: (VDD, V_X, V_A, V_B, V_C, V_D, I)."""
    samples = []
    for idv, vd in enumerate(V_GATE):
        for ic, vc in enumerate(V_GATE):
            for ib, vb in enumerate(V_GATE):
                for ia, va in enumerate(V_GATE):
                    print(f"  pd A={va:.2f} B={vb:.2f} C={vc:.2f} D={vd:.2f}")
                    sp = f"""* pulldown TH34W2 A={va} B={vb} C={vc} D={vd}
.include "{MODELS}"
VVDD VDD 0 {vdd_pwl(T_SIM)}
VVSS VSS 0 0
VA   A   0 {va}
VB   B   0 {vb}
VC   C   0 {vc}
VD   D   0 {vd}
VX   X   0 {vx_pwl(T_SIM)}
MNAB1 Q1 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAB2 X  B Q1  VSS sg13g2_nmos W=0.7u L=0.13u
MNAC1 Q2 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAC2 X  C Q2  VSS sg13g2_nmos W=0.7u L=0.13u
MNAD1 Q3 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAD2 X  D Q3  VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD1 Q4 B VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD2 Q5 C Q4  VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD3 X  D Q5  VSS sg13g2_nmos W=0.7u L=0.13u
.tran {T_SAMPLE}n {T_SIM}n
.print tran format=csv time v(VDD) v(X) i(VX)
.end
"""
                    path = f"{WORK}/pd_{ia}_{ib}_{ic}_{idv}.sp"
                    open(path, "w").write(sp)
                    hdr, d = run_xyce(path)
                    col_vdd = hdr.index("V(VDD)")
                    col_vx  = hdr.index("V(X)")
                    col_i   = hdr.index("I(VX)")
                    for row in range(d.shape[0]):
                        samples.append((float(d[row, col_vdd]),
                                        float(d[row, col_vx]),
                                        va, vb, vc, vd,
                                        float(d[row, col_i])))
    return np.array(samples)


def main():
    print("[1/2] pull-up PWL scatter (625 runs)")
    pu = sweep_pullup()
    print(f"  scatter shape {pu.shape}  |I|max={np.abs(pu[:, -1]).max():.2e} A")

    print("[2/2] pull-down PWL scatter (625 runs)")
    pd = sweep_pulldown()
    print(f"  scatter shape {pd.shape}  |I|max={np.abs(pd[:, -1]).max():.2e} A")

    out = "/tmp/th34w2_char/tables.npz"
    np.savez(out, pu=pu, pd=pd)
    print(f"Saved {out}  (cols: VDD, V_X, V_A, V_B, V_C, V_D, I)")


if __name__ == "__main__":
    main()
