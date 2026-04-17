#!/usr/bin/env python3
"""Tune the 8 R/C/Vt parameters of th22_phys.va to match transistor SPICE.

Objective: V(Y) trace RMSE vs /usr/local/src/ldx/asic/tb/tb_th22.sp.csv on
the 7-phase 4-phase-NCL test. Parameters:
    R_ON, R_OFF, R_KEEP, R_INV   — resistances
    C_X, C_Y                      — capacitances
    VT, K_SLOPE                   — threshold detector

Uses scipy.optimize (Nelder-Mead) on log-scaled R/C variables, linear-scaled
VT/K. Rewrites th22_phys.va's parameter defaults on each objective call and
re-runs Xyce on tb_th22_phys.sp.
"""

import csv
import os
import re
import subprocess
import sys
import numpy as np

XYCE = "/usr/local/src/Xyce-8/xyce-build/src/Xyce"
PLUGIN = "/usr/local/src/kestrel/sim/psp103_sg13g2.so"
VA_PATH = "/usr/local/src/ldx/asic/cells/th22_phys.va"
GT_CSV = "/usr/local/src/ldx/asic/tb/tb_th22.sp.csv"
TB_DIR = "/usr/local/src/ldx/asic/tb"
PHYS_TB = os.path.join(TB_DIR, "tb_th22_phys.sp")


def emit_phys_tb():
    """Emit the test-bench that instantiates th22_phys via .hdl — same
    stimulus as tb_th22.sp."""
    with open(PHYS_TB, "w") as f:
        f.write("""* tb_th22_phys.sp — physical-model TH22, same 7-phase stimulus as tb_th22.sp
.hdl "/usr/local/src/ldx/asic/cells/th22_phys.va"
.model th22_mod th22_phys

VVDD VDD 0 1.2
VVSS VSS 0 0

VA A 0 PWL
+ 0n      0
+ 9.9n    0
+ 10.1n   1.2
+ 19.9n   1.2
+ 20.1n   0
+ 29.9n   0
+ 30.1n   1.2
+ 39.9n   1.2
+ 40.1n   0
+ 49.9n   0
+ 50.1n   1.2
+ 59.9n   1.2
+ 60.1n   0
VB B 0 PWL
+ 0n      0
+ 29.9n   0
+ 30.1n   1.2
+ 59.9n   1.2
+ 60.1n   0

Xdut A B Y VDD VSS th22_mod
CLOAD Y 0 5f

.tran 10p 70n
.print tran format=csv V(A) V(B) V(Y)
.end
""")


# Parameter names + initial log-space seed + bounds (log10 for R/C, linear for VT/K)
PARAMS = [
    # (name,       init,      log-scaled, lo,      hi)
    ("R_ON",       2.0e3,    True,  1e2,    1e5),
    ("R_OFF",      1.0e9,    True,  1e7,    1e11),
    ("R_KEEP",     2.0e5,    True,  1e3,    1e8),
    ("R_INV",      1.5e3,    True,  1e2,    1e5),
    ("C_X",        1.0e-15,  True,  1e-17,  1e-13),
    ("C_Y",        5.0e-15,  True,  1e-16,  1e-13),
    ("VT",         0.6,      False, 0.3,    0.9),
    ("K_SLOPE",    80.0,     False, 10.0,   500.0),
]


def x_to_params(x):
    """Decode optimiser vector x → dict of SI-unit param values."""
    out = {}
    for (name, init, is_log, lo, hi), xi in zip(PARAMS, x):
        if is_log:
            out[name] = 10.0 ** xi
        else:
            out[name] = xi
    return out


def params_to_x(p_dict):
    x = []
    for name, init, is_log, lo, hi in PARAMS:
        v = p_dict.get(name, init)
        x.append(np.log10(v) if is_log else v)
    return np.array(x, dtype=float)


def write_va_with_params(p_dict):
    """Rewrite th22_phys.va in place with the given parameter defaults."""
    with open(VA_PATH) as f:
        text = f.read()
    for name, val in p_dict.items():
        # Match a full numeric literal including `e+03` / `e-15` exponents.
        text = re.sub(
            rf"(parameter\s+real\s+{name}\s*=\s*)"
            rf"([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)",
            lambda m, v=val: f"{m.group(1)}{v:.6e}",
            text,
            count=1,
        )
    with open(VA_PATH, "w") as f:
        f.write(text)


def run_xyce_get_vy():
    """Run Xyce on tb_th22_phys.sp via the cadence2xyce preprocessor; return
    uniform-grid (t, V_Y) arrays."""
    subprocess.run(["rm", "-rf", "/tmp/pyms_hdl_cache"], check=False)
    fixed_tb = PHYS_TB.replace(".sp", "_fixed.sp")
    subprocess.run(
        ["perl", "/usr/local/src/Xyce-8/xyce/utils/cadence2xyce.pl",
         PHYS_TB, "-o", fixed_tb],
        check=False, capture_output=True,
    )
    r = subprocess.run(
        [XYCE, fixed_tb], capture_output=True, text=True, cwd=TB_DIR
    )
    csv_path = fixed_tb + ".csv"
    if r.returncode != 0 or not os.path.exists(csv_path):
        return None, None
    with open(csv_path) as f:
        rows = list(csv.reader(f))
    hdr = [h.strip().upper() for h in rows[0]]
    col_t = hdr.index("TIME")
    col_y = hdr.index("V(Y)")
    data = np.array([[float(x) for x in row] for row in rows[1:]])
    return data[:, col_t], data[:, col_y]


def load_gt():
    with open(GT_CSV) as f:
        rows = list(csv.reader(f))
    hdr = [h.strip().upper() for h in rows[0]]
    data = np.array([[float(x) for x in row] for row in rows[1:]])
    return data[:, 0], data[:, hdr.index("V(Y)")]


def objective(x, gt_t, gt_y, grid_t):
    """RMSE between model V(Y) and transistor GT on a common grid."""
    # Clip x to bounds
    for i, (_, _, is_log, lo, hi) in enumerate(PARAMS):
        b_lo = np.log10(lo) if is_log else lo
        b_hi = np.log10(hi) if is_log else hi
        x[i] = max(b_lo, min(b_hi, x[i]))

    p = x_to_params(x)
    write_va_with_params(p)
    t, y = run_xyce_get_vy()
    if t is None:
        return 10.0    # big penalty on failure

    # Interpolate to common grid
    y_model = np.interp(grid_t, t, y)
    y_gt = np.interp(grid_t, gt_t, gt_y)
    mask = grid_t >= 1e-9     # skip t=0 transient seed
    err = y_model[mask] - y_gt[mask]
    rmse = float(np.sqrt(np.mean(err ** 2)))
    print(f"  rmse={rmse*1e3:7.2f} mV   R_ON={p['R_ON']:.2e}  R_KEEP={p['R_KEEP']:.2e}  "
          f"C_X={p['C_X']:.2e}  VT={p['VT']:.3f}  K={p['K_SLOPE']:.1f}")
    return rmse


def main():
    emit_phys_tb()
    gt_t, gt_y = load_gt()
    grid_t = np.linspace(0, 70e-9, 1401)

    # Sanity run with initial params
    x0 = np.array([np.log10(p[1]) if p[2] else p[1] for p in PARAMS])
    print("Initial:")
    print(f"  x0 = {x0}")
    rmse0 = objective(x0.copy(), gt_t, gt_y, grid_t)
    print(f"Initial RMSE: {rmse0*1e3:.2f} mV")

    # Nelder-Mead tuning
    from scipy.optimize import minimize
    print("\nTuning with Nelder-Mead...")
    res = minimize(
        objective,
        x0,
        args=(gt_t, gt_y, grid_t),
        method="Nelder-Mead",
        options={"xatol": 0.05, "fatol": 0.001, "maxiter": 200, "disp": True},
    )
    x_best = res.x
    p_best = x_to_params(x_best)
    write_va_with_params(p_best)
    rmse_best = objective(x_best.copy(), gt_t, gt_y, grid_t)
    print(f"\nTuned RMSE: {rmse_best*1e3:.2f} mV  ({rmse_best/rmse0*100:.1f}% of initial)")
    print("Tuned parameters:")
    for k, v in p_best.items():
        print(f"  {k} = {v:.4e}")


if __name__ == "__main__":
    main()
