#!/usr/bin/env python3
"""extract_cell_va.py — learn a Verilog-A behavioral model of an NCL cell
from transistor-level SPICE simulation, using Atalanta-generated test
patterns and a Widrow-style adaptive neural network.

Pipeline for a named cell (e.g. TH22):
  1. Emit an ISCAS89 .bench for the combinational abstraction of the cell.
  2. Run Atalanta → enumerate stuck-at test patterns.
  3. For each pattern, synthesise a 4-phase NULL→DATA→NULL SPICE stimulus
     and run Xyce on the transistor-level cell. Capture V(in), V(out), I(VDD).
  4. Train a Widrow/MADALINE-style network (tapped delay line + small
     nonlinear hidden layer, LMS-with-backprop update) to predict V(out)
     and VDD conductance G_VDD from the recent input history.
  5. Emit a Verilog-A module with the trained weights baked in:
       V(out) is driven as an internal voltage source through a fixed R
       to the output port (forming an RC with the external load cap).
       Supply current is modelled as a programmable resistor between
       VDD and VSS, whose conductance is the second NN output.

Usage:
  python3 extract_cell_va.py th22
"""

import argparse
import csv
import json
import os
import subprocess
import sys

CWD = os.path.dirname(os.path.abspath(__file__))
ASIC = os.path.abspath(os.path.join(CWD, ".."))

XYCE = "/usr/local/src/Xyce-8/xyce-build/src/Xyce"
PSP_PLUGIN = "/usr/local/src/kestrel/sim/psp103_sg13g2.so"
ATALANTA = "/usr/local/src/Atalanta/atalanta"
ATALANTA_MAN = "/usr/local/src/Atalanta"
MODELS = "/tmp/sg13g2_models.lib"

VDD_NOM = 1.2
# VDD sweep for training — targets generalisation across supply range.
# SG13G2 low-voltage nominal is 1.2V; actual operating range ±15%.
VDD_SWEEP = [0.90, 1.05, 1.20, 1.35, 1.50]
DATA_NS = 8
NULL_NS = 8
EDGE_PS = 50
SAMPLE_DT_PS = 50   # training sample spacing
N_TAPS = 6          # tapped delay line length

# ==============================================================================
# Cell registry — combinational abstraction + port ordering
# ==============================================================================
CELLS = {
    "th22": {
        "inputs": ["A", "B"],
        "output": "Y",
        "bench": ["INPUT(A)", "INPUT(B)", "OUTPUT(Y)", "Y = AND(A, B)"],
        "spice_include": [
            f"{ASIC}/cells/th22.sp",
        ],
        "subckt": "th22",
        # port order in the .subckt line: A B Y VDD VSS
        "port_order": ["A", "B", "Y", "VDD", "VSS"],
    },
}

# ==============================================================================
# Minimal numpy-like operations (avoid external deps)
# ==============================================================================
try:
    import numpy as np
except ImportError:
    print("numpy required; try: pip install numpy", file=sys.stderr)
    sys.exit(1)

# ==============================================================================
# 1. Atalanta
# ==============================================================================
def run_atalanta(cell_name, spec):
    """Write bench, run atalanta, return list of input-bit patterns."""
    bench_path = os.path.join(CWD, f"{cell_name}.bench")
    with open(bench_path, "w") as f:
        f.write(f"# {cell_name}\n")
        for line in spec["bench"]:
            f.write(line + "\n")

    env = os.environ.copy()
    env["ATALANTA_MAN"] = ATALANTA_MAN
    res = subprocess.run(
        [ATALANTA, f"{cell_name}.bench"],
        cwd=CWD, env=env, capture_output=True, text=True
    )
    if res.returncode != 0:
        print("Atalanta stderr:", res.stderr)
        raise RuntimeError("atalanta failed")

    test_path = os.path.join(CWD, f"{cell_name}.test")
    patterns = []
    with open(test_path) as f:
        in_data = False
        for line in f:
            line = line.strip()
            if "Test patterns" in line:
                in_data = True
                continue
            if not in_data or not line:
                continue
            # "   1: 01010 11"
            if ":" in line:
                _, rest = line.split(":", 1)
                parts = rest.strip().split()
                if parts and all(c in "01" for c in parts[0]):
                    patterns.append(parts[0])
    return patterns


# ==============================================================================
# 2. Xyce characterisation
# ==============================================================================
def pwl_source(name, high_during_data, vhi):
    """PWL source rising to vhi during the single DATA phase."""
    pts = [
        (0.0, 0),
        (NULL_NS - EDGE_PS / 1000, 0),
        (NULL_NS + EDGE_PS / 1000, vhi if high_during_data else 0),
        (NULL_NS + DATA_NS - EDGE_PS / 1000, vhi if high_during_data else 0),
        (NULL_NS + DATA_NS + EDGE_PS / 1000, 0),
        (NULL_NS * 2 + DATA_NS, 0),
    ]
    out = [f"V{name} {name} 0 PWL"]
    for t, v in pts:
        out.append(f"+ {t:.3f}n {v}")
    return "\n".join(out)


def make_stimulus_netlist(cell_name, spec, pattern_bits, pattern_id, vdd):
    """Build a full SPICE deck exercising the cell with one 4-phase pattern at a chosen VDD."""
    inputs = spec["inputs"]
    assert len(pattern_bits) == len(inputs)
    sim_ns = NULL_NS * 2 + DATA_NS

    lines = [
        f"* {cell_name} char stim — pattern #{pattern_id} bits={pattern_bits} VDD={vdd}",
        f'.include "{MODELS}"',
    ]
    for inc in spec["spice_include"]:
        lines.append(f'.include "{inc}"')

    lines += [
        f"VVDD VDD 0 {vdd}",
        "VVSS VSS 0 0",
        "",
    ]

    for name, bit in zip(inputs, pattern_bits):
        lines.append(pwl_source(name, bit == "1", vdd))
        lines.append("")

    # Build DUT port list from spec['port_order']
    port_list = []
    for p in spec["port_order"]:
        if p in inputs or p == spec["output"] or p in ("VDD", "VSS"):
            port_list.append(p)
        else:
            raise RuntimeError(f"unknown port {p}")
    lines.append("Xdut " + " ".join(port_list) + f" {spec['subckt']}")
    lines.append(f"CL{spec['output']} {spec['output']} 0 3f")

    lines += [
        "",
        f".tran {SAMPLE_DT_PS}p {sim_ns}n",
        f".print tran format=csv "
        f"{' '.join('V(' + n + ')' for n in inputs)} "
        f"V({spec['output']}) V(VDD) I(VVDD)",
        ".options timeint method=gear",
        ".end",
    ]
    return "\n".join(lines)


def run_xyce(netlist_path):
    res = subprocess.run(
        [XYCE, "-plugin", PSP_PLUGIN, netlist_path],
        capture_output=True, text=True
    )
    if "Xyce Abort" in res.stdout or res.returncode != 0:
        print("Xyce stdout tail:\n", res.stdout[-1500:])
        raise RuntimeError("Xyce aborted")
    csv_path = netlist_path + ".csv"
    with open(csv_path) as f:
        rows = list(csv.reader(f))
    hdr = [h.strip().upper() for h in rows[0]]
    data = np.array([[float(x) for x in r] for r in rows[1:]])
    return hdr, data


def resample_uniform(hdr, data, dt_ns):
    """Resample simulation output to a uniform grid at dt_ns spacing."""
    t = data[:, 0]
    t_start, t_end = float(t[0]), float(t[-1])
    dt_s = dt_ns * 1e-9
    n = int((t_end - t_start) / dt_s) + 1
    t_u = t_start + np.arange(n) * dt_s
    out = np.zeros((n, data.shape[1]))
    out[:, 0] = t_u
    for j in range(1, data.shape[1]):
        out[:, j] = np.interp(t_u, t, data[:, j])
    return hdr, out


def characterise_cell(cell_name, spec, patterns, vdd_sweep):
    """Run Xyce on every (pattern, VDD) combination; return resampled dataset."""
    dataset = []
    idx = 0
    for bits in patterns:
        for vdd in vdd_sweep:
            stim_path = os.path.join(CWD, f"_stim_{cell_name}_{idx:03d}.sp")
            with open(stim_path, "w") as f:
                f.write(make_stimulus_netlist(cell_name, spec, bits, idx, vdd))
            hdr, data = run_xyce(stim_path)
            hdr, data = resample_uniform(hdr, data, SAMPLE_DT_PS / 1000)
            dataset.append({"bits": bits, "vdd": vdd, "hdr": hdr, "data": data})
            print(f"  pattern {idx:3d} bits={bits} VDD={vdd:.2f}V -> {data.shape[0]} samples")
            idx += 1
    return dataset


# ==============================================================================
# 3. Widrow-style adaptive NN
# ==============================================================================
def build_windows(dataset, spec, n_taps=None):
    """Convert per-pattern traces to (X, Y) arrays for training.

    Feature vector per sample:
        [V(in_0), ..., V(VDD), V(out)_prev]

    V(out)_prev provides state memory so the NN can learn hysteresis
    (C-element hold). Rate features are NOT used — event-driven VHDL
    evaluates at 10+ns granularity and the finite-difference rate blows
    up the NN inputs; keeping features scale-consistent across SPICE
    training and NVC runtime is more important than having ddt features.

    Target Y = [V(out), I(VDD)].
    """
    inputs = spec["inputs"]
    out = spec["output"]
    X_all, Y_all = [], []
    for entry in dataset:
        hdr = entry["hdr"]
        data = entry["data"]
        col = {h: j for j, h in enumerate(hdr)}
        in_cols = [col[f"V({n.upper()})"] for n in inputs]
        vdd_col = col["V(VDD)"]
        out_col = col[f"V({out.upper()})"]
        i_col = col["I(VVDD)"]
        n_samp = data.shape[0]
        for k in range(1, n_samp):
            xrow = [data[k, j] for j in in_cols]
            xrow.append(data[k, vdd_col])
            xrow.append(data[k - 1, out_col])    # V(Y)_prev — state memory
            X_all.append(xrow)
            i_vdd = -data[k, i_col]
            Y_all.append([data[k, out_col], i_vdd])
    return np.array(X_all), np.array(Y_all)


class CellNN:
    """Small MLP trained with LMS-style SGD.
    Input  -> Hidden (leaky-ReLU) -> Output (linear)
    """
    def __init__(self, n_in, n_hid=8, n_out=2, seed=1):
        rng = np.random.default_rng(seed)
        self.W1 = rng.normal(0, 0.3, (n_in, n_hid))
        self.b1 = np.zeros(n_hid)
        self.W2 = rng.normal(0, 0.3, (n_hid, n_out))
        self.b2 = np.zeros(n_out)

    LEAKY_ALPHA = 0.01  # leaky-ReLU slope for negative side

    def forward(self, X):
        self.X = X
        self.z1 = X @ self.W1 + self.b1
        # Leaky-ReLU — unbounded (hidden nodes aren't voltages, no rail
        # constraint); cheap in VHDL/VA (single compare, no tanh library
        # call).  Output clamping happens at the external driver boundary.
        self.h = np.where(self.z1 > 0, self.z1, self.LEAKY_ALPHA * self.z1)
        self.y = self.h @ self.W2 + self.b2
        return self.y

    def train(self, X, Y, lr=1e-2, target_mse=1e-4, max_epochs=5000,
              batch=256, patience=100, plateau_tol=1e-6):
        """Widrow-style SGD; loops until train MSE ≤ target_mse or no
        improvement in `patience` epochs (plateau). Caps at max_epochs.

        Returns (history, stop_reason).
        """
        n = X.shape[0]
        history = []
        best_mse = float('inf')
        plateau_count = 0
        stop = "max_epochs"
        for ep in range(max_epochs):
            idx = np.random.permutation(n)
            mse_acc = 0.0
            for s in range(0, n, batch):
                b_idx = idx[s:s + batch]
                xb, yb = X[b_idx], Y[b_idx]
                yp = self.forward(xb)
                err = yp - yb
                m = xb.shape[0]
                dW2 = self.h.T @ err / m
                db2 = err.mean(axis=0)
                dh = err @ self.W2.T
                # Leaky-ReLU sub-gradient: 1 where z1 > 0, else LEAKY_ALPHA.
                dz1 = dh * np.where(self.z1 > 0, 1.0, self.LEAKY_ALPHA)
                dW1 = xb.T @ dz1 / m
                db1 = dz1.mean(axis=0)
                self.W2 -= lr * dW2
                self.b2 -= lr * db2
                self.W1 -= lr * dW1
                self.b1 -= lr * db1
                mse_acc += (err ** 2).sum()
            mse = mse_acc / (n * Y.shape[1])
            history.append(mse)
            if best_mse - mse > plateau_tol:
                best_mse = mse
                plateau_count = 0
            else:
                plateau_count += 1
            if ep % 25 == 0 or mse <= target_mse:
                print(f"  epoch {ep:4d}  mse={mse:.6f}  best={best_mse:.6f}  plateau={plateau_count}")
            if mse <= target_mse:
                stop = "target_reached"
                break
            if plateau_count >= patience:
                stop = "plateau"
                break
        return history, stop


# ==============================================================================
# 4. Verilog-A emission
# ==============================================================================
def format_array(a, name, per_line=4):
    flat = a.reshape(-1)
    lines = [f"// {name}: shape {a.shape}"]
    for i in range(0, len(flat), per_line):
        chunk = ", ".join(f"{v:+.6e}" for v in flat[i:i + per_line])
        lines.append(f"    // {chunk}")
    return "\n".join(lines)


def emit_verilog_a(cell_name, spec, nn, out_path, variant="analog"):
    """Emit a VA module.

    variant = "analog":
        Single file containing the analog-process form — NN forward pass +
        discrete-driver contributions (V source, series R, grounded C,
        programmable supply R). All Kirchhoff analog in the solver matrix,
        so SPEF-back-annotated parasitics compose cleanly with these drivers.

    variant = "discrete":
        NN core VA module has only two output-tap contributions (v_pred
        and g_pred exposed on internal electrical nodes). A companion
        SPICE subckt wraps that core with real SPICE primitives — VCVS
        (E-element) for the Thevenin V source, series R, grounded C, and
        VCCS (G-element) for the programmable supply. All V/R/C/G are
        thereby discrete netlist elements, not analog contributions, so
        the wrapper sits naturally in a SPEF-less structural flow.
    """
    inputs = spec["inputs"]
    out = spec["output"]
    n_hid = nn.W1.shape[1]

    # Feature vector matches build_windows:
    #   [V(in_0), ..., V(VDD), V(out)_prev]
    # In the VA we use V(out) directly (self-referential — the analog solver
    # iterates Newton until it's a fixed point; this is how hysteresis latches).
    x_refs_va = []
    for nm in inputs:
        x_refs_va.append(f"V({nm}, VSS)")
    x_refs_va.append("V(VDD, VSS)")
    x_refs_va.append(f"V({out}, VSS)")      # self-feedback for hysteresis
    assert len(x_refs_va) == nn.W1.shape[0], (len(x_refs_va), nn.W1.shape[0])

    # Emit scalar variables, not arrays — PyMS VAE parser's assignment path
    # only matches `IDENT = ...`; `array[i] = ...` falls into the EXPR
    # fallback and codegen skips EXPR nodes, so the whole forward pass
    # would be silently dropped.
    alpha = nn.LEAKY_ALPHA
    hidden_body = []
    for j in range(n_hid):
        terms = [f"{nn.W1[i, j]:+.6e}*{x_refs_va[i]}" for i in range(len(x_refs_va))]
        expr = " + ".join(terms)
        hidden_body.append(f"    z1_{j} = {expr} + ({nn.b1[j]:+.6e});")
        # Leaky-ReLU: cheap, unbounded; no tanh library call.
        hidden_body.append(
            f"    h_{j} = (z1_{j} > 0.0 ? z1_{j} : {alpha:.4f} * z1_{j});"
        )

    out_body = []
    for k in range(2):
        terms = [f"{nn.W2[j, k]:+.6e}*h_{j}" for j in range(n_hid)]
        out_body.append(f"    y_{k} = {' + '.join(terms)} + ({nn.b2[k]:+.6e});")

    if variant == "analog":
        va = build_va_analog(cell_name, spec, nn, n_hid, hidden_body, out_body)
        with open(out_path, "w") as f:
            f.write(va)
        return

    # ---- discrete variant: core VA + SPICE wrapper ----
    if variant == "discrete":
        core_path = out_path.replace(".va", "_core.va")
        wrap_path = out_path.replace(".va", "_discrete.sp")
        core = build_va_core_discrete(cell_name, spec, nn, n_hid, hidden_body, out_body)
        with open(core_path, "w") as f:
            f.write(core)
        wrap = build_spice_wrapper_discrete(cell_name, spec)
        with open(wrap_path, "w") as f:
            f.write(wrap)
        return

    # ---- event-driven VHDL for NVC + sv2ghdl resolver-generator ----
    if variant == "event":
        vhdl_path = out_path.replace(".va", ".vhd")
        vhdl = build_vhdl_event(cell_name, spec, nn, n_hid)
        with open(vhdl_path, "w") as f:
            f.write(vhdl)
        return

    raise ValueError(f"unknown variant {variant}")


def build_va_analog(cell_name, spec, nn, n_hid, hidden_body, out_body):
    """Verilog-AMS: NN forward pass + analog drivers in one module.

    NN reads V(inputs), V(VDD), V(out) (self-feedback for hysteresis),
    and ddt() rates; computes v_pred and g_pred via scalar leaky-ReLU
    layers (no arrays, no @(timer) — PyMS VAE compatible); emits four analog
    drivers (Thevenin V+R + grounded C on output, programmable R on
    supply). AMS-native simulators handle it directly; PyMS can compile
    it provided the analog evaluator tolerates leaky-ReLU and self-referential
    V() reads (standard VAMS).
    """
    inputs = spec["inputs"]
    out = spec["output"]
    return f"""// {cell_name}_nn.va — NN cell model (Verilog-AMS, analog + NN).
// Inputs: {', '.join(inputs)}   Output: {out}   Supply: VDD, VSS
// Trained on transistor-level Xyce sweep [{', '.join(f'{v:.2f}' for v in VDD_SWEEP)} V]
// with V({out}) self-feedback for hysteresis; {n_hid} leaky-ReLU hidden.

`include "disciplines.vams"
`include "constants.vams"

module {cell_name}_nn({', '.join(inputs)}, {out}, VDD, VSS);
  input  {', '.join(inputs)}, VDD, VSS;
  output {out};
  electrical {', '.join(inputs)}, {out}, VDD, VSS;
  electrical drive_int;

  parameter real r_out   = 500.0;
  parameter real c_out   = 5e-15;
  parameter real g_floor = 1e-9;

  // Scalar NN state — no arrays (PyMS VAE parses scalar `ident = ...`
  // as ASSIGN; array lvalues fall through to EXPR and are dropped).
{chr(10).join(f'  real z1_{j}, h_{j};' for j in range(n_hid))}
  real y_0, y_1, v_pred, g_pred, vdd_now;

  analog begin
    // ---- NN forward pass (runs every Newton iteration) ----
{chr(10).join(hidden_body)}

{chr(10).join(out_body)}

    v_pred  = y_0;
    vdd_now = V(VDD, VSS);
    g_pred  = g_floor + (y_1 > 0 ? y_1 : 0);
    if (v_pred > vdd_now) v_pred = vdd_now;
    if (v_pred < 0)       v_pred = 0;

    // ---- Analog drivers ----
    V(drive_int, VSS)   <+ v_pred;
    V(drive_int, {out}) <+ I(drive_int, {out}) * r_out;
    I({out}, VSS)       <+ c_out * ddt(V({out}, VSS));
    I(VDD, VSS)         <+ V(VDD, VSS) * g_pred;
  end
endmodule
"""


def build_va_core_discrete(cell_name, spec, nn, n_hid, hidden_body, out_body):
    """Core NN module: exposes v_pred and g_pred on internal electrical taps.
    The four drive components (V source, R, C, programmable R) are NOT in this
    module — they live in the companion SPICE wrapper as real SPICE primitives.
    """
    inputs = spec["inputs"]
    return f"""// {cell_name}_nn_core.va — pure NN core, minimum analog footprint.
// Exports v_pred on node VPRED_TAP and g_pred on node GPRED_TAP.
// Forward pass runs every Newton iteration with instantaneous V() and
// ddt() primitives (no @(timer), no tapped arrays) so PyMS VAE captures it.

`include "disciplines.vams"
`include "constants.vams"

module {cell_name}_nn_core({', '.join(inputs)}, VDD, VSS, VPRED_TAP, GPRED_TAP);
  input  {', '.join(inputs)}, VDD, VSS;
  output VPRED_TAP, GPRED_TAP;
  electrical {', '.join(inputs)}, VDD, VSS, VPRED_TAP, GPRED_TAP;

  parameter real g_floor = 1e-9;

  real z1[0:{n_hid - 1}];
  real h[0:{n_hid - 1}];
  real y[0:1];
  real v_pred, g_pred, vdd_now;

  analog begin
{chr(10).join(hidden_body)}

{chr(10).join(out_body)}

    v_pred  = y[0];
    vdd_now = V(VDD, VSS);
    g_pred  = g_floor + (y[1] > 0 ? y[1] : 0);
    if (v_pred > vdd_now) v_pred = vdd_now;
    if (v_pred < 0)       v_pred = 0;

    // Only analog footprint: two ideal V sources exporting predictions.
    V(VPRED_TAP, VSS) <+ v_pred;
    V(GPRED_TAP, VSS) <+ g_pred;
  end
endmodule
"""


def build_spice_wrapper_discrete(cell_name, spec):
    """SPICE subckt wrapping the NN core with real V/R/C/G primitives.
    The resolver-generator flow sees four discrete drivers on each of the
    output and supply nets, rather than Verilog-A branch contributions.
    """
    inputs = spec["inputs"]
    out = spec["output"]
    core_hdl = f"{cell_name}_nn_core"
    return f"""* {cell_name}_nn_discrete.sp — discrete-primitive wrapper around the NN core.
* Compose with: .hdl "{cell_name}_nn_core.va"

.subckt {cell_name}_nn {' '.join(inputs)} {out} VDD VSS
* --- NN core: pure prediction, two output voltage taps ---
X_core {' '.join(inputs)} VDD VSS vpred_tap gpred_tap {core_hdl}

* --- Discrete Thevenin output driver: VCVS + series R + grounded C ---
E_drive drive_int VSS vpred_tap VSS 1.0
R_out   drive_int {out} 500
C_out   {out} VSS 5f

* --- Programmable supply resistor: VCCS reading g_pred and V(VDD,VSS).
* Equivalent to R = 1/g_pred between VDD and VSS. G = g_pred · V(VDD,VSS).
B_pwr   VDD VSS I={{V(gpred_tap, VSS) * V(VDD, VSS)}}
.ends
"""


def build_vhdl_event(cell_name, spec, nn, n_hid):
    """Emit an event-driven VHDL module for the NN cell.

    Forward pass runs in a process woken on any input event. Feature vector
    mirrors build_windows: [V(in_0), V(in_1), ..., V(VDD), ddt(in_0), ddt(in_1), ...].
    Rate features kept as signal history via a small previous-value cache
    plus wall-clock `now`-delta so the process can compute finite-difference
    ddt without a timer. Emits three separate drivers (Thevenin on output,
    grounded C on output, programmable R on supply) that the sv2ghdl resolver-
    generator composes — grounded caps just sum across drivers.
    """
    inputs = spec["inputs"]
    out_port = spec["output"]
    n_in = len(inputs)

    in_ports = ";\n    ".join(f"{n} : in logic3da" for n in inputs)
    # Feature vector: V(in_i).voltage, V(VDD).voltage, V(out)_prev
    x_refs = [f"{n}.voltage" for n in inputs] + ["VDD.voltage", "y_prev"]
    assert len(x_refs) == nn.W1.shape[0], (len(x_refs), nn.W1.shape[0])

    # VHDL constants for weight matrices, emitted as flat real_vector with
    # row-major indexing (no 2D matrix type needed — avoids depending on
    # packages that may not ship the helper).
    def emit_matrix(M, name):
        rows = M.shape[0]
        cols = M.shape[1]
        flat = M.reshape(-1)
        init = ", ".join(f"{v:+.6e}" for v in flat)
        return (f"  constant {name} : real_vector(0 to {rows * cols - 1}) := "
                f"({init});\n"
                f"  constant {name}_COLS : integer := {cols};")

    def emit_vector(v, name):
        init = ", ".join(f"{x:+.6e}" for x in v)
        return f"  constant {name} : real_vector(0 to {len(v)-1}) := ({init});"

    # Hidden-layer and output-layer expressions. W is a flat real_vector with
    # W(r, c) = W(r*COLS + c) row-major. Deep indent (10 spaces) because
    # these lines land inside loop+if+for inside the main process.
    n_x = len(x_refs)
    NN_INDENT = "          "
    hidden_eval = []
    for j in range(n_hid):
        terms = " + ".join(
            f"W1({i * n_hid + j})*{x_refs[i]}"
            for i in range(n_x)
        )
        hidden_eval.append(f"{NN_INDENT}z1({j}) := {terms} + b1({j});")
        hidden_eval.append(
            f"{NN_INDENT}if z1({j}) > 0.0 then h({j}) := z1({j}); "
            f"else h({j}) := {nn.LEAKY_ALPHA:.4f} * z1({j}); end if;"
        )
    out_eval = []
    for k in range(2):
        terms = " + ".join(f"W2({j * 2 + k})*h({j})" for j in range(n_hid))
        out_eval.append(f"{NN_INDENT}y({k}) := {terms} + b2({k});")

    # Zone tracking: one integer per input. Zone 0 = LOW (below Vtn, NMOS off,
    # PMOS may be on), 1 = ACTIVE (transistors conducting, edge in progress),
    # 2 = HIGH (above VDD-|Vtp|, NMOS may be on, PMOS off). We re-run the
    # forward pass only when an input's zone changes — between zones the
    # network's output is effectively latched by the keeper / hysteresis
    # and the output driver is re-asserted unchanged. This mirrors the
    # hybrid_evt cell (th22_hybrid_evt.vhd) and matches NCL semantics where
    # inputs switch cleanly between rails.
    zone_var_names = [f"z_{n.lower()}" for n in inputs]
    zone_new_names = [f"{v}_new" for v in zone_var_names]
    zone_decls = (
        "    variable " + ", ".join(zone_var_names) + " : integer := 0;\n"
        "    variable " + ", ".join(zone_new_names) + " : integer;"
    )
    zone_compute = "\n".join(
        f"    {new} := zone({inp}.voltage, vdd_now);"
        for inp, new in zip(inputs, zone_new_names)
    )
    zone_change_cond = " or ".join(
        f"{new} /= {cur}" for new, cur in zip(zone_new_names, zone_var_names)
    )
    zone_commit = "\n".join(
        f"      {cur} := {new};" for cur, new in zip(zone_var_names, zone_new_names)
    )

    # State memory — y_prev holds previous NN output for hysteresis feedback.
    rate_decls = "    variable y_prev : real := 0.0;"
    rate_compute = ["    -- (no rate features; state via y_prev only)"]

    return f"""-- {cell_name}_nn.vhd — NN-extracted event-driven VHDL cell model.
-- Generated by /usr/local/src/ldx/asic/chr/extract_cell_va.py (variant=event).
--
-- Uses NVC's logic3da_pkg (sv2vhdl library) for Thevenin-equivalent analog
-- signals. V(output) is a resolved logic3da net — NVC's built-in
-- l3da_resolve composes all drivers (parallel-Thevenin combination) with
-- no matrix solve. Process wakes on input events, runs NN forward pass,
-- emits a single logic3da driver onto the output net. Grounded C and
-- supply-R contributions are separate outputs that aggregator processes
-- sum onto the relevant nets.

library ieee;
use ieee.math_real.all;
use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity {cell_name}_nn is
  port (
    -- Input nets carry Thevenin-equivalent analog signal (voltage+R)
    {in_ports};
    VDD  : in  logic3da;
    VSS  : in  logic3da;
    -- Single Thevenin driver on output net (NVC resolves in parallel).
    {out_port}_drv  : out logic3da;
    -- Grounded-C contribution (resolver just sums these across drivers).
    {out_port}_cap  : out real;
    -- Programmable-R contribution across supply (conductance-form driver).
    VDD_drv : out logic3da
  );
end entity;

architecture nn_event of {cell_name}_nn is
  constant R_OUT    : real := 500.0;        -- Thevenin series R (output)
  constant C_OUT    : real := 5.0e-15;      -- grounded output capacitance
  constant G_FLOOR  : real := 1.0e-9;       -- supply conductance floor
  constant R_PWR_HI : real := 1.0e9;        -- supply R ceiling (safety)

  -- SG13G2 PSP103 transistor thresholds. Pull-down (NMOS) begins conducting
  -- at V_gate > Vtn; pull-up (PMOS) at V_gate < VDD - |Vtp|. The NN
  -- evaluates only when an input crosses one of these thresholds.
  constant VTN     : real := 0.40;
  constant VTP_ABS : real := 0.35;

  -- Zone encoding: 0=LOW (< Vtn), 1=ACTIVE (transistors mid-switch), 2=HIGH.
  function zone(v, vdd : real) return integer is
  begin
    if v < VTN then return 0;
    elsif v > vdd - VTP_ABS then return 2;
    else return 1;
    end if;
  end function;

{emit_matrix(nn.W1, "W1")}
{emit_vector(nn.b1, "b1")}
{emit_matrix(nn.W2, "W2")}
{emit_vector(nn.b2, "b2")}

  signal v_pred : real := 0.0;
  signal g_pred : real := G_FLOOR;
begin
  -- NN forward pass — event-driven wake-up on rail departure. The process
  -- holds state in `y_prev` across wake-ups and evaluates only when one of
  -- the inputs enters / leaves its ACTIVE zone. Matches the hybrid_evt
  -- cell; drastically reduces simulator work on long NCL hold phases.
  nn_proc : process
{rate_decls}
{zone_decls}
    variable z1, h : real_vector(0 to {n_hid - 1});
    variable y     : real_vector(0 to 1);
    variable vp, gp, vdd_now : real;
  begin
{chr(10).join(rate_compute)}

    -- Prime the driver at t=0 so downstream nets see a defined value
    -- before the first input edge.
    v_pred <= 0.0;
    g_pred <= G_FLOOR;

    loop
      wait on {", ".join(inputs + ["VDD"])};

      vdd_now := VDD.voltage;
{zone_compute}

      -- Skip NN forward pass if no input's zone changed — the keeper /
      -- hysteresis built into the NN's fixed point is already at its
      -- steady value for the current zone configuration.
      if {zone_change_cond} then
{zone_commit}

        -- Fixed-point iteration of the NN forward pass with V(out) self-
        -- feedback. Inside one wake-up we need to converge y_prev because
        -- the process loop is what schedules the next wait — no implicit
        -- re-trigger like the old `process(..., y_drv)` form.
        for iter in 0 to 31 loop
          -- Hidden layer (leaky-ReLU)
{chr(10).join(hidden_eval)}
          -- Output layer
{chr(10).join(out_eval)}

          vp := y(0);
          gp := G_FLOOR;
          if y(1) > 0.0 then gp := gp + y(1); end if;
          if vp > vdd_now    then vp := vdd_now;      end if;
          if vp < VSS.voltage then vp := VSS.voltage; end if;

          exit when abs(vp - y_prev) < 1.0e-4;
          y_prev := vp;
        end loop;

        v_pred <= vp;
        g_pred <= gp;
        y_prev := vp;
      end if;
    end loop;
  end process;

  -- Emit Thevenin driver on output net {out_port}: voltage = v_pred,
  -- source resistance R_OUT. NVC's l3da_resolve composes this with any
  -- other drivers on the same resolved net.
  {out_port}_drv <= (voltage => v_pred, resistance => R_OUT,
                     flags => AFL_KNOWN);

  -- Grounded-C contribution (resolver sums these across drivers).
  {out_port}_cap <= C_OUT;

  -- Programmable supply R: emit on VDD_drv as a logic3da driver between
  -- VDD and VSS (equivalent to a resistor of value 1/g_pred).
  VDD_drv <= (voltage => VSS.voltage, resistance => 1.0 / g_pred,
              flags => AFL_KNOWN);

end architecture;
"""


# ==============================================================================
# Main pipeline
# ==============================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cell", help="cell name (e.g. th22)")
    ap.add_argument("--target-mse", type=float, default=5e-4,
                    help="Train until MSE (on scaled output) is at or below this")
    ap.add_argument("--max-epochs", type=int, default=5000)
    ap.add_argument("--hidden", type=int, default=12)
    args = ap.parse_args()

    if args.cell not in CELLS:
        print(f"Unknown cell '{args.cell}'. Known: {list(CELLS)}", file=sys.stderr)
        sys.exit(1)

    spec = CELLS[args.cell]

    print(f"[1/4] Atalanta stuck-at patterns for {args.cell}")
    patterns = run_atalanta(args.cell, spec)
    # Augment with all-zero and all-one for corner coverage (NCL reset & full-high)
    all_zero = "0" * len(spec["inputs"])
    all_one = "1" * len(spec["inputs"])
    for p in [all_zero, all_one]:
        if p not in patterns:
            patterns.append(p)
    print(f"  patterns: {patterns}")

    print(f"[2/4] Xyce characterisation across VDD sweep {VDD_SWEEP} V")
    dataset = characterise_cell(args.cell, spec, patterns, VDD_SWEEP)

    print(f"[3/4] Build training windows + NN fit")
    X, Y = build_windows(dataset, spec, N_TAPS)
    print(f"  X shape {X.shape}  Y shape {Y.shape}")
    # Training targets:
    #   Y[:,0] = V(out) in volts      — scale is O(1)
    #   Y[:,1] = I(VDD) in amps       — scale is ~10-100 µA → scale up for stability
    # We fit in (volts, mA) space, then fold the mA→A back into output weights,
    # and convert current → conductance by dividing by the corresponding V(VDD)
    # sample (which is the last tap_VDD[0] at the current instant).
    #
    # Conductance formulation: G_pred = I_pred / V(VDD) lets the VA scale
    # naturally across supply — at lower VDD the predicted current drops too.
    Y_train = Y.copy()
    Y_train[:, 1] = Y[:, 1] * 1e3  # amps → milliamps for conditioning

    # Divide training current target by corresponding V(VDD) sample to learn
    # conductance directly. Feature vector layout: [V(in_0),...,V(VDD), ddt(...)],
    # so V(VDD) is at column index = n_inputs.
    vdd_t = X[:, len(spec["inputs"])]
    # Protect divide
    vdd_safe = np.where(vdd_t > 0.05, vdd_t, 0.05)
    Y_train[:, 1] = (Y[:, 1] / vdd_safe) * 1e3  # conductance, scaled to mS

    nn = CellNN(n_in=X.shape[1], n_hid=args.hidden, n_out=2)
    hist, stop = nn.train(X, Y_train, lr=5e-3, target_mse=args.target_mse,
                          max_epochs=args.max_epochs, batch=128)
    print(f"  final train mse: {hist[-1]:.6f}   stop reason: {stop}   epochs: {len(hist)}")

    # Post-train rescale: y[1] was trained in mS; VA uses SI conductance.
    nn.W2[:, 1] *= 1e-3
    nn.b2[1] *= 1e-3

    print(f"[4/4] Emit model artifacts — three variants")
    va_path = os.path.join(ASIC, "cells", f"{args.cell}_nn.va")
    emit_verilog_a(args.cell, spec, nn, va_path, variant="analog")
    emit_verilog_a(args.cell, spec, nn, va_path, variant="discrete")
    emit_verilog_a(args.cell, spec, nn, va_path, variant="event")

    core_path = va_path.replace(".va", "_core.va")
    wrap_path = va_path.replace(".va", "_discrete.sp")
    vhdl_path = va_path.replace(".va", ".vhd")

    summary = {
        "cell": args.cell,
        "patterns": patterns,
        "X_shape": list(X.shape),
        "Y_shape": list(Y.shape),
        "train_mse_final": float(hist[-1]),
        "va_path_analog": va_path,
        "va_path_discrete_core": core_path,
        "va_path_discrete_wrapper": wrap_path,
        "vhdl_path_event": vhdl_path,
    }
    with open(os.path.join(CWD, f"{args.cell}_summary.json"), "w") as f:
        json.dump(summary, f, indent=2)

    print(f"\nAnalog-process VA         : {va_path}")
    print(f"Discrete core VA          : {core_path}")
    print(f"Discrete SPICE wrapper    : {wrap_path}")
    print(f"Event-driven VHDL (NVC)   : {vhdl_path}")
    print(f"Summary: {summary}")


if __name__ == "__main__":
    main()
