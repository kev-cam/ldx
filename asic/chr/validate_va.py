#!/usr/bin/env python3
"""Validate the trained NN model against held-out Xyce ground truth.

Runs Xyce at a VDD that was NOT in the training sweep (e.g. 1.275V when
training used 0.9/1.05/1.20/1.35/1.50), replays the same input pattern
through the NN in Python, and reports prediction error on V(Y) and I(VDD).
"""
import csv, json, os, sys, subprocess
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_cell_va import (
    CELLS, N_TAPS, SAMPLE_DT_PS, VDD_SWEEP,
    make_stimulus_netlist, run_xyce, resample_uniform, CellNN
)

CWD = os.path.dirname(os.path.abspath(__file__))

def load_trained_weights(cell_name):
    """Reconstruct the trained NN from the emitted VA file by parsing weights."""
    va_path = f"/usr/local/src/ldx/asic/cells/{cell_name}_nn.va"
    text = open(va_path).read()

    # Parse z1[i] = ... lines for hidden weights + biases
    import re
    hidden_lines = re.findall(r"z1\[(\d+)\]\s*=\s*(.+?);", text)
    out_lines = re.findall(r"y\[(\d+)\]\s*=\s*(.+?);", text)
    n_hid = len(hidden_lines)
    n_out = len(out_lines)

    def parse_linear(expr):
        """'w1*tap_A[0] + w2*tap_A[1] + ... + (bias)' → (weights_dict, bias)"""
        # Split off trailing bias (in parens)
        m = re.match(r"(.+)\s*\+\s*\(([-+0-9.eE]+)\)\s*$", expr.strip())
        if not m:
            raise ValueError(expr)
        terms_s, bias_s = m.group(1), m.group(2)
        bias = float(bias_s)
        weights = {}
        for term in terms_s.split("+"):
            term = term.strip().lstrip("+")
            # e.g. "-5.962867e-02*tap_A[1]" or "+3.649345e-02*tap_A[0]"
            tm = re.match(r"([-+]?[0-9.eE+-]+)\*(\w+\[\d+\])", term)
            if not tm:
                # hidden lookups are like h[0]
                tm = re.match(r"([-+]?[0-9.eE+-]+)\*(h\[\d+\])", term)
            if tm:
                weights[tm.group(2)] = float(tm.group(1))
        return weights, bias

    # Determine x variable order from first hidden line
    first_expr = hidden_lines[0][1]
    w_dict, _ = parse_linear(first_expr)
    x_order = list(w_dict.keys())
    n_in = len(x_order)

    W1 = np.zeros((n_in, n_hid))
    b1 = np.zeros(n_hid)
    for j, expr in hidden_lines:
        j = int(j)
        w, b = parse_linear(expr)
        for i, name in enumerate(x_order):
            W1[i, j] = w[name]
        b1[j] = b

    h_order = [f"h[{j}]" for j in range(n_hid)]
    W2 = np.zeros((n_hid, n_out))
    b2 = np.zeros(n_out)
    for k, expr in out_lines:
        k = int(k)
        w, b = parse_linear(expr)
        for j, name in enumerate(h_order):
            W2[j, k] = w[name]
        b2[k] = b

    nn = CellNN(n_in=n_in, n_hid=n_hid, n_out=n_out)
    nn.W1[:] = W1
    nn.b1[:] = b1
    nn.W2[:] = W2
    nn.b2[:] = b2
    return nn, x_order


def replay(nn, x_order, spec, hdr, data, n_taps):
    """Run the NN forward pass over the recorded waveform.
    Returns (v_pred, g_pred) per time step."""
    inputs = spec["inputs"]
    col = {h: j for j, h in enumerate(hdr)}
    in_cols = [col[f"V({n.upper()})"] for n in inputs]
    vdd_col = col["V(VDD)"]
    out_col = col[f"V({spec['output']}).".rstrip('.').upper()]
    i_col = col["I(VVDD)"]
    n_samp = data.shape[0]

    v_pred = np.zeros(n_samp)
    g_pred = np.zeros(n_samp)
    for k in range(n_taps, n_samp):
        x = []
        for j in in_cols:
            for p in range(n_taps):
                x.append(data[k - p, j])
        for p in range(n_taps):
            x.append(data[k - p, vdd_col])
        y = nn.forward(np.array([x]))[0]
        v_pred[k] = y[0]
        # y[1] is conductance (SI) after post-train rescale applied in extract script
        g_pred[k] = y[1] if y[1] > 0 else 0
    return v_pred, g_pred


def main():
    cell = "th22"
    spec = CELLS[cell]

    # Held-out VDD midway between training corners
    vdd_test = 1.275
    assert vdd_test not in VDD_SWEEP, "vdd_test leaked into training"

    # Also use patterns Atalanta would emit + corners
    patterns = ["01", "10", "11", "00"]

    nn, x_order = load_trained_weights(cell)
    print(f"Loaded NN: W1 {nn.W1.shape}, W2 {nn.W2.shape}")
    print(f"Held-out VDD: {vdd_test} V")

    results = []
    for i, bits in enumerate(patterns):
        stim_path = os.path.join(CWD, f"_val_{cell}_{i}.sp")
        with open(stim_path, "w") as f:
            f.write(make_stimulus_netlist(cell, spec, bits, i, vdd_test))
        hdr, data = run_xyce(stim_path)
        hdr, data = resample_uniform(hdr, data, SAMPLE_DT_PS / 1000)
        hdr_up = [h.strip().upper() for h in hdr]

        # Replay
        col = {h: j for j, h in enumerate(hdr_up)}
        v_true = data[:, col[f"V({spec['output']})".upper()]]
        i_true = -data[:, col["I(VVDD)"]]     # draw current as positive
        v_pred, g_pred = replay(nn, x_order, spec, hdr_up, data, N_TAPS)
        i_pred = g_pred * data[:, col["V(VDD)"]]

        # Metrics over the DATA+NULL window (exclude startup taps)
        mask = slice(N_TAPS, data.shape[0])
        v_rmse = float(np.sqrt(np.mean((v_pred[mask] - v_true[mask]) ** 2)))
        i_rmse = float(np.sqrt(np.mean((i_pred[mask] - i_true[mask]) ** 2)))
        v_max = float(np.max(np.abs(v_pred[mask] - v_true[mask])))
        q_true = float(np.trapz(i_true[mask], data[mask, 0]))
        q_pred = float(np.trapz(i_pred[mask], data[mask, 0]))
        print(
            f"  pattern {bits}  V(Y) RMSE={v_rmse*1000:.2f} mV  "
            f"maxerr={v_max*1000:.1f} mV   "
            f"Q_true={q_true*1e15:.1f} fC  Q_pred={q_pred*1e15:.1f} fC  "
            f"({100*(q_pred-q_true)/abs(q_true+1e-18):+.1f}%)"
        )
        results.append({
            "pattern": bits, "vdd": vdd_test,
            "v_rmse_mV": v_rmse * 1000, "v_maxerr_mV": v_max * 1000,
            "q_true_fC": q_true * 1e15, "q_pred_fC": q_pred * 1e15,
        })

    with open(os.path.join(CWD, f"{cell}_validation.json"), "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nWrote {cell}_validation.json")


if __name__ == "__main__":
    main()
