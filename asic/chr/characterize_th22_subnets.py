#!/usr/bin/env python3
"""Characterize the four sub-networks of TH22 with Xyce DC sweeps, emit
an IV-table VAMS module.

Sub-networks (see cells/th22.sp):
  pull-up   : VDD → MPA(A) → N1 → MPB(B) → X          I_pu(V_X, V_A, V_B)
  pull-down : VSS → MNA(A) → N2 → MNB(B) → X          I_pd(V_X, V_A, V_B)
  keeper    : VDD/VSS → MPK/MNK(gate=Y) → X           I_kp(V_X, V_Y)
  inverter  : VDD/VSS → MPY/MNY(gate=X) → Y           I_inv(V_Y, V_X)

Currents are measured as net flow INTO the output node of each sub-net from
the VDD/VSS rails. Tables are stored as flat `real` arrays in the emitted
Verilog-A module plus shape constants; a small inline trilinear/bilinear
interpolator handles lookups.

Characterisation grid: V_{X,Y} at 13 points (0..VDD step 0.1V), gate-input
voltages at 5 points (0..VDD step 0.3V). VDD fixed at 1.2V for this pass
(could be extended to a VDD sweep later).
"""

import csv
import os
import subprocess
import sys
import numpy as np

XYCE = "/usr/local/src/Xyce-8/xyce-build/src/Xyce"
PLUGIN = "/usr/local/src/kestrel/sim/psp103_sg13g2.so"
MODELS = "/tmp/sg13g2_models.lib"

# SG13G2 nominal VDD is 1.2V; spec'd operating range ±25%. Sweep 5
# points covering 0.9..1.5V so NN/IV-table cells can scale predictions
# across supply variation (previously single-VDD characterisation
# caused NN cells to fail at VDD < 1.0V — see commit b798105).
VDD_LIST = [0.9, 1.05, 1.2, 1.35, 1.5]
VDD = VDD_LIST[2]   # legacy alias; kept for code that still reads VDD

V_OUT = np.linspace(0.0, 1.5, 13)            # output-node sweep (absolute)
V_GATE = np.linspace(0.0, 1.5, 5)            # gate input sweep (absolute)

WORK = "/tmp/th22_char"
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
    """I_pu(VDD, V_X, V_A, V_B): MPA & MPB PMOS in series VDD→X.
    4-D table over [VDD, V_X, V_A, V_B]."""
    data = np.zeros((len(VDD_LIST), len(V_OUT), len(V_GATE), len(V_GATE)))
    for iv, vd in enumerate(VDD_LIST):
        print(f"  pu VDD={vd:.2f}")
        for ib, vb in enumerate(V_GATE):
            for ia, va in enumerate(V_GATE):
                sp = f"""* pullup characterization VDD={vd} A={va} B={vb}
.include "{MODELS}"
VVDD VDD 0 {vd}
VA   A   0 {va}
VB   B   0 {vb}
VX   X   0 0
MPA  N1 A VDD VDD sg13g2_pmos w=0.7u  l=0.13u
MPB  X  B N1  VDD sg13g2_pmos w=0.7u  l=0.13u
.dc VX 0 {V_OUT[-1]} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
                path = f"{WORK}/pu_{iv}_{ia}_{ib}.sp"
                open(path, "w").write(sp)
                hdr, d = run_xyce(path)
                col_i = hdr.index("I(VX)")
                for ix in range(len(V_OUT)):
                    data[iv, ix, ia, ib] = float(d[ix, col_i])
    return data


def sweep_pulldown():
    """I_pd(VDD, V_X, V_A, V_B): MNA & MNB NMOS in series X→VSS."""
    data = np.zeros((len(VDD_LIST), len(V_OUT), len(V_GATE), len(V_GATE)))
    for iv, vd in enumerate(VDD_LIST):
        print(f"  pd VDD={vd:.2f}")
        for ib, vb in enumerate(V_GATE):
            for ia, va in enumerate(V_GATE):
                sp = f"""* pulldown characterization VDD={vd} A={va} B={vb}
.include "{MODELS}"
VVSS VSS 0 0
VA   A   0 {va}
VB   B   0 {vb}
VX   X   0 0
MNA  N2 A VSS VSS sg13g2_nmos w=0.35u l=0.13u
MNB  X  B N2  VSS sg13g2_nmos w=0.35u l=0.13u
.dc VX 0 {V_OUT[-1]} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
                path = f"{WORK}/pd_{iv}_{ia}_{ib}.sp"
                open(path, "w").write(sp)
                hdr, d = run_xyce(path)
                col_i = hdr.index("I(VX)")
                for ix in range(len(V_OUT)):
                    data[iv, ix, ia, ib] = float(d[ix, col_i])
    return data


def sweep_keeper():
    """I_kp(VDD, V_X, V_Y): weak inverter MPK/MNK — VDD-swept."""
    data = np.zeros((len(VDD_LIST), len(V_OUT), len(V_OUT)))
    for iv, vd in enumerate(VDD_LIST):
        print(f"  kp VDD={vd:.2f}")
        for iy, vy in enumerate(V_OUT):
            sp = f"""* keeper VDD={vd} Y={vy}
.include "{MODELS}"
VVDD VDD 0 {vd}
VVSS VSS 0 0
VY   Y   0 {vy}
VX   X   0 0
MPK  X  Y VDD VDD sg13g2_pmos w=0.35u l=1.0u
MNK  X  Y VSS VSS sg13g2_nmos w=0.15u l=1.0u
.dc VX 0 {V_OUT[-1]} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(X) i(VX)
.end
"""
            path = f"{WORK}/kp_{iv}_{iy}.sp"
            open(path, "w").write(sp)
            hdr, d = run_xyce(path)
            col_i = hdr.index("I(VX)")
            for ix in range(len(V_OUT)):
                data[iv, ix, iy] = float(d[ix, col_i])
    return data


def sweep_inverter():
    """I_inv(VDD, V_Y, V_X): MPY/MNY output inverter — VDD-swept."""
    data = np.zeros((len(VDD_LIST), len(V_OUT), len(V_OUT)))
    for iv, vd in enumerate(VDD_LIST):
        print(f"  inv VDD={vd:.2f}")
        for ix, vx in enumerate(V_OUT):
            sp = f"""* inverter VDD={vd} X={vx}
.include "{MODELS}"
VVDD VDD 0 {vd}
VVSS VSS 0 0
VX   X   0 {vx}
VY   Y   0 0
MPY  Y  X VDD VDD sg13g2_pmos w=0.7u  l=0.13u
MNY  Y  X VSS VSS sg13g2_nmos w=0.35u l=0.13u
.dc VY 0 {V_OUT[-1]} {V_OUT[1]-V_OUT[0]:.3f}
.print dc format=csv v(Y) i(VY)
.end
"""
            path = f"{WORK}/inv_{iv}_{ix}.sp"
            open(path, "w").write(sp)
            hdr, d = run_xyce(path)
            col_i = hdr.index("I(VY)")
            for iy in range(len(V_OUT)):
                data[iv, iy, ix] = float(d[iy, col_i])
    return data


# ---- Emit the VAMS module ----
def emit_vams(pu, pd, kp, inv, out_path):
    NX = len(V_OUT); NG = len(V_GATE)

    def fmt_flat(arr, name):
        s = ", ".join(f"{v:+.4e}" for v in arr.reshape(-1))
        return f"  parameter real {name}[0:{arr.size-1}] = '{{{s}}};"

    def emit_lu3(prefix, vx_expr, va_expr, vb_expr, table_name, out_var):
        """Emit inline trilinear interpolation of `table_name` at (vx, va, vb).
        All locals are named with `prefix` so we can call it multiple times."""
        # Keep expressions simple — Xyce parses better with explicit parens.
        NG2 = NG * NG
        return f"""    // --- {out_var} = lu3({table_name}, {vx_expr}, {va_expr}, {vb_expr}) ---
    {prefix}_fx = ({vx_expr}) / DX;
    if ({prefix}_fx < 0.0) {prefix}_fx = 0.0;
    if ({prefix}_fx > {NX-1}) {prefix}_fx = {NX-1};
    {prefix}_fa = ({va_expr}) / DG;
    if ({prefix}_fa < 0.0) {prefix}_fa = 0.0;
    if ({prefix}_fa > {NG-1}) {prefix}_fa = {NG-1};
    {prefix}_fb = ({vb_expr}) / DG;
    if ({prefix}_fb < 0.0) {prefix}_fb = 0.0;
    if ({prefix}_fb > {NG-1}) {prefix}_fb = {NG-1};
    {prefix}_ix = floor({prefix}_fx);
    if ({prefix}_ix > {NX-2}) {prefix}_ix = {NX-2};
    {prefix}_ia = floor({prefix}_fa);
    if ({prefix}_ia > {NG-2}) {prefix}_ia = {NG-2};
    {prefix}_ib = floor({prefix}_fb);
    if ({prefix}_ib > {NG-2}) {prefix}_ib = {NG-2};
    {prefix}_fx = {prefix}_fx - {prefix}_ix;
    {prefix}_fa = {prefix}_fa - {prefix}_ia;
    {prefix}_fb = {prefix}_fb - {prefix}_ib;
    {prefix}_v000 = {table_name}[({prefix}_ix    )*{NG2} + ({prefix}_ia    )*{NG} + ({prefix}_ib    )];
    {prefix}_v100 = {table_name}[({prefix}_ix + 1)*{NG2} + ({prefix}_ia    )*{NG} + ({prefix}_ib    )];
    {prefix}_v010 = {table_name}[({prefix}_ix    )*{NG2} + ({prefix}_ia + 1)*{NG} + ({prefix}_ib    )];
    {prefix}_v001 = {table_name}[({prefix}_ix    )*{NG2} + ({prefix}_ia    )*{NG} + ({prefix}_ib + 1)];
    {prefix}_v110 = {table_name}[({prefix}_ix + 1)*{NG2} + ({prefix}_ia + 1)*{NG} + ({prefix}_ib    )];
    {prefix}_v101 = {table_name}[({prefix}_ix + 1)*{NG2} + ({prefix}_ia    )*{NG} + ({prefix}_ib + 1)];
    {prefix}_v011 = {table_name}[({prefix}_ix    )*{NG2} + ({prefix}_ia + 1)*{NG} + ({prefix}_ib + 1)];
    {prefix}_v111 = {table_name}[({prefix}_ix + 1)*{NG2} + ({prefix}_ia + 1)*{NG} + ({prefix}_ib + 1)];
    {prefix}_c00 = {prefix}_v000*(1 - {prefix}_fx) + {prefix}_v100*{prefix}_fx;
    {prefix}_c10 = {prefix}_v010*(1 - {prefix}_fx) + {prefix}_v110*{prefix}_fx;
    {prefix}_c01 = {prefix}_v001*(1 - {prefix}_fx) + {prefix}_v101*{prefix}_fx;
    {prefix}_c11 = {prefix}_v011*(1 - {prefix}_fx) + {prefix}_v111*{prefix}_fx;
    {prefix}_c0  = {prefix}_c00 *(1 - {prefix}_fa) + {prefix}_c10 *{prefix}_fa;
    {prefix}_c1  = {prefix}_c01 *(1 - {prefix}_fa) + {prefix}_c11 *{prefix}_fa;
    {out_var} = {prefix}_c0 *(1 - {prefix}_fb) + {prefix}_c1 *{prefix}_fb;
"""

    def emit_lu2(prefix, vo_expr, vg_expr, table_name, out_var):
        return f"""    // --- {out_var} = lu2({table_name}, {vo_expr}, {vg_expr}) ---
    {prefix}_fo = ({vo_expr}) / DX;
    if ({prefix}_fo < 0.0) {prefix}_fo = 0.0;
    if ({prefix}_fo > {NX-1}) {prefix}_fo = {NX-1};
    {prefix}_fg = ({vg_expr}) / DX;
    if ({prefix}_fg < 0.0) {prefix}_fg = 0.0;
    if ({prefix}_fg > {NX-1}) {prefix}_fg = {NX-1};
    {prefix}_io = floor({prefix}_fo);
    if ({prefix}_io > {NX-2}) {prefix}_io = {NX-2};
    {prefix}_ig = floor({prefix}_fg);
    if ({prefix}_ig > {NX-2}) {prefix}_ig = {NX-2};
    {prefix}_fo = {prefix}_fo - {prefix}_io;
    {prefix}_fg = {prefix}_fg - {prefix}_ig;
    {prefix}_v00 = {table_name}[({prefix}_io    )*{NX} + ({prefix}_ig    )];
    {prefix}_v10 = {table_name}[({prefix}_io + 1)*{NX} + ({prefix}_ig    )];
    {prefix}_v01 = {table_name}[({prefix}_io    )*{NX} + ({prefix}_ig + 1)];
    {prefix}_v11 = {table_name}[({prefix}_io + 1)*{NX} + ({prefix}_ig + 1)];
    {prefix}_c0  = {prefix}_v00 *(1 - {prefix}_fo) + {prefix}_v10 *{prefix}_fo;
    {prefix}_c1  = {prefix}_v01 *(1 - {prefix}_fo) + {prefix}_v11 *{prefix}_fo;
    {out_var} = {prefix}_c0 *(1 - {prefix}_fg) + {prefix}_c1 *{prefix}_fg;
"""

    def lu3_locals(prefix):
        names = [f"{prefix}_fx", f"{prefix}_fa", f"{prefix}_fb",
                 f"{prefix}_v000", f"{prefix}_v100", f"{prefix}_v010",
                 f"{prefix}_v001", f"{prefix}_v110", f"{prefix}_v101",
                 f"{prefix}_v011", f"{prefix}_v111",
                 f"{prefix}_c00", f"{prefix}_c10", f"{prefix}_c01",
                 f"{prefix}_c11", f"{prefix}_c0", f"{prefix}_c1"]
        ints  = [f"{prefix}_ix", f"{prefix}_ia", f"{prefix}_ib"]
        return names, ints

    def lu2_locals(prefix):
        names = [f"{prefix}_fo", f"{prefix}_fg",
                 f"{prefix}_v00", f"{prefix}_v10",
                 f"{prefix}_v01", f"{prefix}_v11",
                 f"{prefix}_c0",  f"{prefix}_c1"]
        ints  = [f"{prefix}_io", f"{prefix}_ig"]
        return names, ints

    # Collect local vars for each interp call site
    lu3_reals, lu3_ints = set(), set()
    lu2_reals, lu2_ints = set(), set()
    for pfx in ("pu", "pd"):
        r, i = lu3_locals(pfx); lu3_reals.update(r); lu3_ints.update(i)
    for pfx in ("kp", "inv"):
        r, i = lu2_locals(pfx); lu2_reals.update(r); lu2_ints.update(i)

    decls = []
    decls.append("  real i_pu, i_pd, i_kp, i_inv;")
    if lu3_reals:
        decls.append("  real " + ", ".join(sorted(lu3_reals)) + ";")
    if lu3_ints:
        decls.append("  integer " + ", ".join(sorted(lu3_ints)) + ";")
    if lu2_reals:
        decls.append("  real " + ", ".join(sorted(lu2_reals)) + ";")
    if lu2_ints:
        decls.append("  integer " + ", ".join(sorted(lu2_ints)) + ";")

    va = f'''// th22_tbl.va — TH22 C-element, IV-table model from transistor DC sweeps.
// Auto-generated by chr/characterize_th22_subnets.py.
//
// Four sub-networks characterised at transistor level:
//   pull-up, pull-down : I(V_X, V_A, V_B)   — 3-D tables ({NX}x{NG}x{NG})
//   keeper, inverter   : I(V_out, V_gate)   — 2-D tables ({NX}x{NX})
// Trilinear / bilinear interpolation inlined in the analog block
// (no analog function declarations — PyMS VAE doesn't parse them).

`include "disciplines.vams"
`include "constants.vams"

module th22_tbl(A, B, Y, VDD, VSS);
  input  A, B, VDD, VSS;
  output Y;
  electrical A, B, Y, VDD, VSS;
  electrical X;

  parameter real C_X = 1.0e-15;
  parameter real C_Y = 5.0e-15;
  parameter real VDD_NOM = {VDD};
  parameter real DX  = {V_OUT[1]-V_OUT[0]:.6f};
  parameter real DG  = {V_GATE[1]-V_GATE[0]:.6f};

{fmt_flat(pu, "T_PU")}

{fmt_flat(pd, "T_PD")}

{fmt_flat(kp, "T_KP")}

{fmt_flat(inv, "T_INV")}

{chr(10).join(decls)}

  analog begin
{emit_lu3("pu", "V(X, VSS)", "V(A, VSS)", "V(B, VSS)", "T_PU", "i_pu")}
{emit_lu3("pd", "V(X, VSS)", "V(A, VSS)", "V(B, VSS)", "T_PD", "i_pd")}
{emit_lu2("kp", "V(X, VSS)", "V(Y, VSS)", "T_KP", "i_kp")}
{emit_lu2("inv", "V(Y, VSS)", "V(X, VSS)", "T_INV", "i_inv")}

    // Sign convention: i_* = "current INTO the node". For I(node, VSS) form
    // this needs negation so KCL balances:  C*dV/dt = Σ i_*.
    I(X, VSS) <+ -(i_pu + i_pd + i_kp);
    I(X, VSS) <+ C_X * ddt(V(X, VSS));

    I(Y, VSS) <+ -i_inv;
    I(Y, VSS) <+ C_Y * ddt(V(Y, VSS));
  end
endmodule
'''
    with open(out_path, "w") as f:
        f.write(va)


def main():
    print("Characterising pull-up...")
    pu = sweep_pullup()
    print("Characterising pull-down...")
    pd = sweep_pulldown()
    print("Characterising keeper...")
    kp = sweep_keeper()
    print("Characterising inverter...")
    inv = sweep_inverter()

    # Quick sanity stats
    for name, arr in [("pull-up", pu), ("pull-down", pd),
                      ("keeper", kp), ("inverter", inv)]:
        print(f"  {name}: shape {arr.shape}   "
              f"min={arr.min():.3e}  max={arr.max():.3e}")

    np.savez("/tmp/th22_char/tables.npz",
             pu=pu, pd=pd, kp=kp, inv=inv,
             vdd_list=np.array(VDD_LIST),
             v_out=V_OUT, v_gate=V_GATE)
    print("\nSaved /tmp/th22_char/tables.npz (4D: VDD × V_OUT × ...)")
    # th22_tbl.va emission disabled — tables are now 4D, old emit_vams
    # is 3D-only. Re-enable with a multi-VDD template if/when needed.


if __name__ == "__main__":
    main()
