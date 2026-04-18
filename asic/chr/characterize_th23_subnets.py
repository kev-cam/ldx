#!/usr/bin/env python3
"""Characterize TH23 sub-networks with Xyce DC sweeps.

TH23 is the 2-of-3 threshold gate (majority with hysteresis). Its
pull-down network has three parallel 2-stack branches (A·B || A·C ||
B·C) instead of TH22's single 2-stack. The pull-up is a 3-PMOS series
stack that only conducts when all three inputs are LOW.

Sub-networks:
  pull-up   : VDD → MPA(A) → MPB(B) → MPC(C) → X     I_pu(V_X, V_A, V_B, V_C)
  pull-down : {A·B, A·C, B·C} parallel              I_pd(V_X, V_A, V_B, V_C)
  inverter  : MPY/MNY (gate=X, output=Y)             I_inv(V_Y, V_X)
  keeper    : MPK/MNK (gate=Y, output=X)             I_kp(V_X, V_Y)

Inverter and keeper are identical to TH22's — we don't re-characterize
them, just reuse the TH22 tables.

Grid: V_X at 13 points (0..VDD 0.1V), each of V_A/V_B/V_C at 5 points.
13×5×5×5 = 1625 points per direction = ~30 minutes of Xyce time.
"""

import csv
import os
import subprocess
import sys
import numpy as np

XYCE = "/usr/local/src/Xyce-8/xyce-build/src/Xyce"
PLUGIN = "/usr/local/src/kestrel/sim/psp103_sg13g2.so"
MODELS = "/tmp/sg13g2_models.lib"
VDD = 1.2

V_OUT = np.linspace(0.0, VDD, 13)
V_GATE = np.linspace(0.0, VDD, 5)

WORK = "/tmp/th23_char"
os.makedirs(WORK, exist_ok=True)


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
    """3-PMOS series stack VDD→X. I_pu > 0 when all three inputs LOW."""
    data = np.zeros((len(V_OUT), len(V_GATE), len(V_GATE), len(V_GATE)))
    n_total = len(V_GATE) ** 3
    done = 0
    for ic, vc in enumerate(V_GATE):
        for ib, vb in enumerate(V_GATE):
            for ia, va in enumerate(V_GATE):
                sp = f"""* pullup TH23 A={va} B={vb} C={vc}
.include "{MODELS}"
VVDD VDD 0 {VDD}
VA   A   0 {va}
VB   B   0 {vb}
VC   C   0 {vc}
VX   X   0 0
MPA  N1 A VDD VDD sg13g2_pmos w=1.0u l=0.13u
MPB  N2 B N1  VDD sg13g2_pmos w=1.0u l=0.13u
MPC  X  C N2  VDD sg13g2_pmos w=1.0u l=0.13u
.dc VX 0 {VDD} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
                path = f"{WORK}/pu_{ia}_{ib}_{ic}.sp"
                open(path, "w").write(sp)
                hdr, d = run_xyce(path)
                col_i = hdr.index("I(VX)")
                for ix in range(len(V_OUT)):
                    data[ix, ia, ib, ic] = float(d[ix, col_i])
                done += 1
                if done % 25 == 0:
                    print(f"  pu: {done}/{n_total}")
    return data


def sweep_pulldown():
    """Three parallel 2-stack branches A·B, A·C, B·C to VSS.
    I_pd < 0 when ≥2 inputs HIGH and V_X > 0."""
    data = np.zeros((len(V_OUT), len(V_GATE), len(V_GATE), len(V_GATE)))
    n_total = len(V_GATE) ** 3
    done = 0
    for ic, vc in enumerate(V_GATE):
        for ib, vb in enumerate(V_GATE):
            for ia, va in enumerate(V_GATE):
                sp = f"""* pulldown TH23 A={va} B={vb} C={vc}
.include "{MODELS}"
VVSS VSS 0 0
VA   A   0 {va}
VB   B   0 {vb}
VC   C   0 {vc}
VX   X   0 0
MNAB1 M1 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAB2 X  B M1  VSS sg13g2_nmos W=0.7u L=0.13u
MNAC1 M2 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAC2 X  C M2  VSS sg13g2_nmos W=0.7u L=0.13u
MNBC1 M3 B VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNBC2 X  C M3  VSS sg13g2_nmos W=0.7u L=0.13u
.dc VX 0 {VDD} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
                path = f"{WORK}/pd_{ia}_{ib}_{ic}.sp"
                open(path, "w").write(sp)
                hdr, d = run_xyce(path)
                col_i = hdr.index("I(VX)")
                for ix in range(len(V_OUT)):
                    data[ix, ia, ib, ic] = float(d[ix, col_i])
                done += 1
                if done % 25 == 0:
                    print(f"  pd: {done}/{n_total}")
    return data


def main():
    if not os.path.exists(MODELS):
        print(f"Missing {MODELS}; run sg13g2 model setup first.", file=sys.stderr)
        sys.exit(1)

    print("[1/2] pull-up sweeps (125 points × 13 V_X each)")
    pu = sweep_pullup()
    print(f"  shape {pu.shape}  |I|max={np.abs(pu).max():.2e} A")

    print("[2/2] pull-down sweeps (125 points × 13 V_X each)")
    pd = sweep_pulldown()
    print(f"  shape {pd.shape}  |I|max={np.abs(pd).max():.2e} A")

    out = "/tmp/th23_char/tables.npz"
    np.savez(out, pu=pu, pd=pd)
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
