#!/usr/bin/env python3
"""Compare V(Y) waveforms from three simulation modes against the
transistor-level ground truth.

Modes:
  1. Transistor (PSP103)        — tb_th22.sp.csv          (ground truth)
  2. NN-VA (PyMS JIT)           — tb_th22_nn_fixed.sp.csv
  3. Behavioural (B-source)     — _tb_th22_beh.sp.csv

Resamples all three to a common 50ps grid, then reports per-phase logic
accuracy, waveform RMSE, peak error, and edge timing vs ground truth.
"""
import csv, os
import numpy as np

CSV_GT   = "tb_th22.sp.csv"
CSV_NN   = "tb_th22_nn_fixed.sp.csv"
CSV_BEH  = "_tb_th22_beh.sp.csv"

def load(path):
    with open(path) as f:
        r = csv.reader(f); hdr = next(r)
        data = np.array([[float(x) for x in row] for row in r])
    col = {h.strip().upper(): i for i, h in enumerate(hdr)}
    return data, col

def resample(data, col, t_grid):
    """Interpolate V(Y) onto t_grid."""
    t = data[:, 0]
    y = data[:, col["V(Y)"]]
    return np.interp(t_grid, t, y)

# Common time grid: 0 to 70 ns, 50 ps step
t_grid = np.linspace(0, 70e-9, 1401)

gt_data, gt_col = load(CSV_GT)
nn_data, nn_col = load(CSV_NN)
beh_data, beh_col = load(CSV_BEH)

y_gt   = resample(gt_data,  gt_col,  t_grid)
y_nn   = resample(nn_data,  nn_col,  t_grid)
y_beh  = resample(beh_data, beh_col, t_grid)

# --- Waveform metrics ---
def metrics(y_pred, y_ref, name):
    err = y_pred - y_ref
    rmse = float(np.sqrt(np.mean(err ** 2)))
    peak = float(np.max(np.abs(err)))
    mae  = float(np.mean(np.abs(err)))
    return {"mode": name, "rmse_mV": rmse*1e3, "peak_mV": peak*1e3, "mae_mV": mae*1e3}

print("=== Waveform error vs transistor ground truth (70ns, 50ps grid) ===")
print(f"{'Mode':25s} {'RMSE':>10s} {'Peak err':>12s} {'MAE':>10s}")
for m in [metrics(y_nn, y_gt, "NN-VA (PyMS JIT)"),
          metrics(y_beh, y_gt, "Behavioural (B-source)")]:
    print(f"{m['mode']:25s} {m['rmse_mV']:>8.2f} mV  {m['peak_mV']:>9.2f} mV  {m['mae_mV']:>7.2f} mV")

# --- Per-phase logic accuracy ---
# 7 phases, 10ns each. Sample mid-phase (5ns in).
print("\n=== Per-phase logic (sample at mid-phase, threshold 0.6V) ===")
print(f"{'Phase':7s} {'Window':14s} {'A,B':6s} {'GT':>6s} {'NN':>8s} {'Beh':>8s}")
phase_defs = [
    (0, 0), (1, 0), (0, 0), (1, 1), (0, 1), (1, 1), (0, 0)
]
labels = ["set 0", "hold 0", "stay 0", "set 1", "hold 1", "stay 1", "set 0"]
for k, ((a, b), lbl) in enumerate(zip(phase_defs, labels)):
    t_mid = (k * 10 + 5) * 1e-9
    idx = np.argmin(np.abs(t_grid - t_mid))
    vgt = y_gt[idx]; vnn = y_nn[idx]; vbeh = y_beh[idx]
    def decode(v): return "1" if v > 0.6 else "0"
    print(f"{k:2d} {lbl:11s} {k*10:>2d}-{(k+1)*10:<2d} ns  {a},{b:1d}  "
          f"{decode(vgt)} ({vgt:5.3f}) "
          f"{decode(vnn)} ({vnn:5.3f}) "
          f"{decode(vbeh)} ({vbeh:5.3f})")

# --- Edge timing ---
def find_edge(y, t, thresh=0.6, rising=True):
    for i in range(1, len(y)):
        if rising and y[i-1] < thresh <= y[i]:
            f = (thresh - y[i-1]) / (y[i] - y[i-1])
            return t[i-1] + f * (t[i] - t[i-1])
        if not rising and y[i-1] > thresh >= y[i]:
            f = (y[i-1] - thresh) / (y[i-1] - y[i])
            return t[i-1] + f * (t[i] - t[i-1])
    return None

print("\n=== Rising edge at DATA set (30-31 ns) ===")
for name, y in [("GT (transistor)", y_gt), ("NN-VA", y_nn), ("Beh", y_beh)]:
    te = find_edge(y, t_grid, 0.6, True)
    if te is None:
        print(f"{name:25s} no edge found")
    else:
        print(f"{name:25s} crosses 0.6V at {te*1e9:.3f} ns")

print("\n=== Falling edge at NULL return (60-61 ns) ===")
for name, y in [("GT (transistor)", y_gt), ("NN-VA", y_nn), ("Beh", y_beh)]:
    te = find_edge(y, t_grid, 0.6, False)
    if te is None:
        print(f"{name:25s} no edge found")
    else:
        print(f"{name:25s} crosses 0.6V at {te*1e9:.3f} ns")
