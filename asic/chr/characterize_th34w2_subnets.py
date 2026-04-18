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

VDD_LIST = [0.9, 1.05, 1.2, 1.35, 1.5]
V_OUT = np.linspace(0.0, 1.5, 13)
V_GATE = np.linspace(0.0, 1.5, 5)

WORK = "/tmp/th34w2_char"
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
    """4-PMOS series stack VDD→X, VDD-swept."""
    NG = len(V_GATE)
    data = np.zeros((len(VDD_LIST), len(V_OUT), NG, NG, NG, NG))
    for iv, vdd_v in enumerate(VDD_LIST):
        print(f"  pu VDD={vdd_v:.2f}")
        for idv, vd in enumerate(V_GATE):
            for ic, vc in enumerate(V_GATE):
                for ib, vb in enumerate(V_GATE):
                    for ia, va in enumerate(V_GATE):
                        sp = f"""* pullup TH34W2 VDD={vdd_v} A={va} B={vb} C={vc} D={vd}
.include "{MODELS}"
VVDD VDD 0 {vdd_v}
VA   A   0 {va}
VB   B   0 {vb}
VC   C   0 {vc}
VD   D   0 {vd}
VX   X   0 0
MPA  P1 A VDD VDD sg13g2_pmos W=1.2u L=0.13u
MPB  P2 B P1  VDD sg13g2_pmos W=1.2u L=0.13u
MPC  P3 C P2  VDD sg13g2_pmos W=1.2u L=0.13u
MPD  X  D P3  VDD sg13g2_pmos W=1.2u L=0.13u
.dc VX 0 {V_OUT[-1]} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
                        path = f"{WORK}/pu_{iv}_{ia}_{ib}_{ic}_{idv}.sp"
                        open(path, "w").write(sp)
                        hdr, d = run_xyce(path)
                        col_i = hdr.index("I(VX)")
                        for ix in range(len(V_OUT)):
                            data[iv, ix, ia, ib, ic, idv] = float(d[ix, col_i])
    return data


def sweep_pulldown():
    """4-branch weighted pull-down: A·B || A·C || A·D || B·C·D, VDD-swept."""
    NG = len(V_GATE)
    data = np.zeros((len(VDD_LIST), len(V_OUT), NG, NG, NG, NG))
    for iv, vdd_v in enumerate(VDD_LIST):
        print(f"  pd VDD={vdd_v:.2f}")
        for idv, vd in enumerate(V_GATE):
            for ic, vc in enumerate(V_GATE):
                for ib, vb in enumerate(V_GATE):
                    for ia, va in enumerate(V_GATE):
                        sp = f"""* pulldown TH34W2 VDD={vdd_v} A={va} B={vb} C={vc} D={vd}
.include "{MODELS}"
VVSS VSS 0 0
VA   A   0 {va}
VB   B   0 {vb}
VC   C   0 {vc}
VD   D   0 {vd}
VX   X   0 0
MNAB1 Q1 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAB2 X  B Q1  VSS sg13g2_nmos W=0.7u L=0.13u
MNAC1 Q2 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAC2 X  C Q2  VSS sg13g2_nmos W=0.7u L=0.13u
MNAD1 Q3 A VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNAD2 X  D Q3  VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD1 Q4 B VSS VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD2 Q5 C Q4  VSS sg13g2_nmos W=0.7u L=0.13u
MNBCD3 X  D Q5  VSS sg13g2_nmos W=0.7u L=0.13u
.dc VX 0 {V_OUT[-1]} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
                        path = f"{WORK}/pd_{iv}_{ia}_{ib}_{ic}_{idv}.sp"
                        open(path, "w").write(sp)
                        hdr, d = run_xyce(path)
                        col_i = hdr.index("I(VX)")
                        for ix in range(len(V_OUT)):
                            data[iv, ix, ia, ib, ic, idv] = float(d[ix, col_i])
    return data


def main():
    print("[1/2] pull-up sweeps (625 points × 13 V_X each)")
    pu = sweep_pullup()
    print(f"  shape {pu.shape}  |I|max={np.abs(pu).max():.2e} A")

    print("[2/2] pull-down sweeps (625 points × 13 V_X each)")
    pd = sweep_pulldown()
    print(f"  shape {pd.shape}  |I|max={np.abs(pd).max():.2e} A")

    out = "/tmp/th34w2_char/tables.npz"
    np.savez(out, pu=pu, pd=pd,
             vdd_list=np.array(VDD_LIST),
             v_out=V_OUT, v_gate=V_GATE)
    print(f"Saved {out}")


if __name__ == "__main__":
    main()
