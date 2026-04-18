#!/usr/bin/env python3
"""extract_nn_hybrid.py — train NN current models on sub-network DC sweeps
and emit a hybrid-topology cell (VA + event-driven VHDL).

Architecture mirrors th22_hybrid.va / th22_hybrid_evt.vhd exactly, except
the IV-table lookups are replaced by small NN forward passes:

  I(X, VSS) <+ -(i_drive)            # NN: (V_X, V_A, V_B) → net pu+pd
  I(X, VSS) <+ -(V(VDD)-V(Y)-V(X))/R_KEEP    # analytical keeper
  I(X, VSS) <+ C_X * ddt(V(X))
  I(Y, VSS) <+ -(i_inv)              # NN: (V_X, V_Y) → inverter
  I(Y, VSS) <+ C_Y * ddt(V(Y))

The analytical keeper is the hand-crafted piece — it supplies the
weak-feedback restoring force that the pure end-to-end NN struggled to
learn. The two NNs handle the smooth MOS drain-current surfaces, which
they fit easily.

Input data: /tmp/th22_char/tables.npz produced by
characterize_th22_subnets.py (13×5×5 pull-up/pull-down, 13×13 inverter).
Runs that script automatically if the cache is missing.
"""

import argparse
import itertools
import os
import subprocess
import sys
import numpy as np

CWD = os.path.dirname(os.path.abspath(__file__))
ASIC = os.path.abspath(os.path.join(CWD, ".."))

VDD_NOM = 1.2
V_OUT = np.linspace(0.0, VDD_NOM, 13)
V_GATE = np.linspace(0.0, VDD_NOM, 5)


# Per-gate config: number of inputs, input port names, characterisation
# cache path, corresponding characterise script.
GATES = {
    "th22": {
        "n_in": 2,
        "ports": ("A", "B"),
        "cache": "/tmp/th22_char/tables.npz",
        "char_script": "characterize_th22_subnets.py",
    },
    "th23": {
        "n_in": 3,
        "ports": ("A", "B", "C"),
        "cache": "/tmp/th23_char/tables.npz",
        "char_script": "characterize_th23_subnets.py",
    },
    "th34w2": {
        "n_in": 4,
        "ports": ("A", "B", "C", "D"),
        "cache": "/tmp/th34w2_char/tables.npz",
        "char_script": "characterize_th34w2_subnets.py",
    },
}


def ensure_tables(gate):
    info = GATES[gate]
    if os.path.exists(info["cache"]):
        return np.load(info["cache"])
    print(f"No cached {gate} tables — running {info['char_script']}")
    subprocess.run(
        [sys.executable, os.path.join(CWD, info["char_script"])],
        check=True,
    )
    return np.load(info["cache"])


# ----------------------------------------------------------------------
# NN — small leaky-ReLU MLP, same shape as extract_cell_va.py's CellNN.
# ----------------------------------------------------------------------
class MLP:
    LEAKY_ALPHA = 0.01

    def __init__(self, n_in, n_hid, n_out=1, seed=1):
        rng = np.random.default_rng(seed)
        self.W1 = rng.normal(0, 0.3, (n_in, n_hid))
        self.b1 = np.zeros(n_hid)
        self.W2 = rng.normal(0, 0.3, (n_hid, n_out))
        self.b2 = np.zeros(n_out)

    def forward(self, X):
        self.X = X
        self.z1 = X @ self.W1 + self.b1
        self.h = np.where(self.z1 > 0, self.z1, self.LEAKY_ALPHA * self.z1)
        return self.h @ self.W2 + self.b2

    def train(self, X, Y, lr=5e-3, target_mse=1e-6, max_epochs=8000,
              batch=64, patience=400):
        n = X.shape[0]
        best = float('inf')
        plateau = 0
        hist = []
        for ep in range(max_epochs):
            idx = np.random.permutation(n)
            mse_acc = 0.0
            for s in range(0, n, batch):
                bi = idx[s:s + batch]
                xb, yb = X[bi], Y[bi]
                yp = self.forward(xb)
                err = yp - yb
                m = xb.shape[0]
                dW2 = self.h.T @ err / m
                db2 = err.mean(axis=0)
                dh = err @ self.W2.T
                dz1 = dh * np.where(self.z1 > 0, 1.0, self.LEAKY_ALPHA)
                dW1 = xb.T @ dz1 / m
                db1 = dz1.mean(axis=0)
                self.W2 -= lr * dW2
                self.b2 -= lr * db2
                self.W1 -= lr * dW1
                self.b1 -= lr * db1
                mse_acc += (err ** 2).sum()
            mse = mse_acc / (n * Y.shape[1])
            hist.append(mse)
            if best - mse > 1e-9:
                best = mse
                plateau = 0
            else:
                plateau += 1
            if ep % 50 == 0:
                print(f"    ep {ep:4d}  mse={mse:.3e}  best={best:.3e}")
            if mse <= target_mse or plateau >= patience:
                break
        return hist


# ----------------------------------------------------------------------
# Build training sets from tables.
# ----------------------------------------------------------------------
def build_drive_dataset(pu, pd, n_in, tables):
    """Combined pull-up + pull-down drive current from PWL scatter data.

    Input shape: pu/pd are (N_samples, 3+n_in) with columns
      (VDD, V_X, V_a, V_b, ..., I).
    Feature vector: (VDD, V_X, V_a, V_b, ...) → drive_current.
    Since pu and pd simulations are independent (different sample
    times), we concatenate their samples rather than summing.
    """
    if pu.ndim == 2:
        # Scatter format: last col is current, first 2+n_in are features.
        X_list = np.concatenate([pu[:, :2+n_in], pd[:, :2+n_in]], axis=0)
        Y_list = np.concatenate([pu[:, -1:], pd[:, -1:]], axis=0)
        return X_list, Y_list
    # Legacy grid fallback (no longer used, but kept for compat).
    raise ValueError("Expected scatter format (N,3+n_in); got shape " + str(pu.shape))


def build_inv_dataset(inv, tables):
    """Inverter scatter: columns (VDD, V_X, V_Y, I)."""
    if inv.ndim == 2:
        return inv[:, :3], inv[:, -1:]
    raise ValueError("Expected scatter format (N,4); got shape " + str(inv.shape))


# ----------------------------------------------------------------------
# Current normalization: PSP currents run up to ~60 µA. Scale into a
# unit range for training stability, then unscale the output layer.
# ----------------------------------------------------------------------
I_SCALE = 1.0e5  # fit in units of 10 µA; rescale W2/b2 after training


def rescale(nn):
    nn.W2 = nn.W2 / I_SCALE
    nn.b2 = nn.b2 / I_SCALE


# ----------------------------------------------------------------------
# VHDL emission — mirrors th22_hybrid_evt.vhd topology.
# ----------------------------------------------------------------------
def emit_vector(v, name, per_line=6):
    items = [f"{x:+.6e}" for x in v.reshape(-1)]
    return (f"  constant {name} : real_vector(0 to {len(items)-1}) := (\n    "
            + ",\n    ".join(", ".join(items[i:i+per_line])
                              for i in range(0, len(items), per_line))
            + "\n  );")


def nn_forward_vhdl(n_in, n_hid, xs, weight_prefix, indent=8):
    """Emit VHDL statements that compute forward pass of a single-output
    NN with given inputs. Writes into a variable `y_<prefix>`.
    xs is a list of VHDL real expressions (e.g. "v_x", "a.voltage").
    Returns a list of indented lines."""
    pad = " " * indent
    out = []
    # z1[j] = sum_i W1[i*n_hid+j]*xs[i] + b1[j]
    for j in range(n_hid):
        terms = " + ".join(
            f"{weight_prefix}_W1({i*n_hid+j})*{xs[i]}"
            for i in range(n_in)
        )
        out.append(f"{pad}z_{weight_prefix}({j}) := {terms} + {weight_prefix}_b1({j});")
        out.append(
            f"{pad}if z_{weight_prefix}({j}) > 0.0 "
            f"then h_{weight_prefix}({j}) := z_{weight_prefix}({j}); "
            f"else h_{weight_prefix}({j}) := 0.01 * z_{weight_prefix}({j}); end if;"
        )
    # y = sum_j W2[j]*h[j] + b2
    terms = " + ".join(
        f"{weight_prefix}_W2({j})*h_{weight_prefix}({j})" for j in range(n_hid)
    )
    out.append(f"{pad}y_{weight_prefix} := {terms} + {weight_prefix}_b2(0);")
    return out


def emit_vhdl(gate, drive_nn, inv_nn, n_hid, out_path):
    ports = GATES[gate]["ports"]
    n_in = GATES[gate]["n_in"]
    # NN inputs: (VDD, V_X, V_a, V_b, ...) — VDD baked in so predictions
    # scale correctly across supply variation.
    drive_xs = ["vdd_v", "V_X_v"] + [f"{p}.voltage" for p in ports]
    drive_fwd = nn_forward_vhdl(
        2 + n_in, n_hid, drive_xs, "drive", indent=8,
    )
    # Port list entries
    port_decls = ";\n    ".join(f"{p}       : in  logic3da" for p in ports)
    # Sensitivity list — all gate inputs + VDD
    wait_list = ", ".join(list(ports) + ["VDD"])
    # Zone variables
    z_curr_names = [f"z_{p.lower()}" for p in ports]
    z_new_names = [f"{z}_new" for z in z_curr_names]
    zone_decl = (
        f"    variable {', '.join(z_curr_names)} : integer := 0;\n"
        f"    variable {', '.join(z_new_names)} : integer;"
    )
    zone_compute = "\n".join(
        f"      {new} := zone({p}.voltage, vdd_v);"
        for p, new in zip(ports, z_new_names)
    )
    zone_change_cond = " or ".join(
        f"{new} /= {cur}" for new, cur in zip(z_new_names, z_curr_names)
    )
    zone_commit = "\n".join(
        f"        {cur} := {new};" for cur, new in zip(z_curr_names, z_new_names)
    )

    vhdl = f"""-- {gate}_nn_hybrid.vhd — NN-predicted drive current + analytical keeper.
--
-- Topology mirrors th22_hybrid_evt.vhd exactly. The IV-table lookup for
-- pull-up + pull-down is replaced by a small leaky-ReLU MLP:
--   drive_nn(V_X, V_A, V_B) → net pull-up+pull-down current into X
-- V(Y) is a digital inversion of V(X) (same rule as hybrid_evt) — the
-- inverter direction is deterministic from V(X), so no NN needed.
-- Hysteresis comes entirely from the hand-crafted analytical keeper
--   I_keep = (VDD - V(Y) - V(X)) / R_KEEP
-- which biases V(X) toward (VDD - V(Y)). When inputs are in a mixed
-- zone (one HIGH, one LOW) the NN predicts ~0 drive current and the
-- keeper holds V(X) at its previous rail.
--
-- Generated by /usr/local/src/ldx/asic/chr/extract_nn_hybrid.py

library ieee;
use ieee.math_real.all;
use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity {gate}_nn_hybrid is
  port (
    {port_decls};
    VDD     : in  logic3da;
    VSS     : in  logic3da;
    Y_drv   : out logic3da;
    Y_cap   : out real;
    VDD_drv : out logic3da
  );
end entity;

architecture evt of {gate}_nn_hybrid is

  constant VTN     : real := 0.40;
  constant VTP_ABS : real := 0.35;

  constant R_OUT   : real := 1.05e4;   -- output inverter effective R
  constant R_KEEP  : real := 8.0e4;    -- analytical keeper
  constant R_STEP  : real := 3.0e4;    -- NN-current → Δv step size

  constant C_X     : real := 6.4e-15;
  constant C_Y     : real := 5.0e-15;

  function zone(v, vdd : real) return integer is
  begin
    if v < VTN then return 0;
    elsif v > vdd - VTP_ABS then return 2;
    else return 1;
    end if;
  end function;

{emit_vector(drive_nn.W1, "drive_W1")}
{emit_vector(drive_nn.b1, "drive_b1")}
{emit_vector(drive_nn.W2, "drive_W2")}
  constant drive_b2 : real_vector(0 to 0) := (0 => {drive_nn.b2[0]:+.6e});

  signal v_y_sig : real := 0.0;

begin

  eval : process
{zone_decl}
    variable vdd_v            : real;
    variable V_X_v            : real := 0.0;  -- internal X node, persistent
    variable v_y              : real := 0.0;
    variable i_drive, i_keep  : real;
    variable i_supply         : real;
    variable z_drive, h_drive : real_vector(0 to {n_hid - 1});
    variable y_drive          : real;
  begin
    Y_drv   <= (voltage => 0.0, resistance => R_OUT, flags => AFL_KNOWN);
    Y_cap   <= C_Y;
    VDD_drv <= (voltage => 0.0, resistance => 1.0e9, flags => AFL_KNOWN);

    loop
      wait on {wait_list};

      vdd_v := VDD.voltage;
{zone_compute}

      if {zone_change_cond} then
{zone_commit}

        -- Newton-style iteration over V(X). At each step:
        --   1. Evaluate NN for i_drive(V_X, V_A, V_B)
        --   2. Evaluate analytical keeper i_keep(V_X, V_Y)
        --   3. Update V_X toward equilibrium: V_X += (i_drive + i_keep) * R_STEP
        -- Then apply digital inverter rule for V(Y). A few iterations
        -- suffice because the NN surface is approximately monotonic in V_X.
        for iter in 0 to 7 loop
{chr(10).join(drive_fwd)}
          i_drive := y_drive;
          i_keep  := (vdd_v - v_y - V_X_v) / R_KEEP;

          V_X_v := V_X_v + (i_drive + i_keep) * R_STEP;
          if V_X_v > vdd_v then V_X_v := vdd_v; end if;
          if V_X_v < 0.0   then V_X_v := 0.0;   end if;

          -- Inverter rule with HOLD zone (completion detection). Only
          -- commit V(Y) to a rail when V(X) is clearly past the PMOS/NMOS
          -- threshold. In between (ACTIVE zone) keep the previous v_y —
          -- this is the event-driven analogue of "the physical inverter
          -- is still mid-transition, so the downstream gate shouldn't
          -- see a new rail yet". Without this the cell snaps to a rail
          -- on every partial input change and the keeper locks it in
          -- prematurely, breaking multi-stage NCL cascades.
          if V_X_v < VTN then
            v_y := vdd_v;
          elsif V_X_v > vdd_v - VTP_ABS then
            v_y := 0.0;
          -- else: hold previous v_y
          end if;
        end loop;

        i_supply := abs(i_drive) + abs(i_keep);

        v_y_sig <= v_y;
        Y_drv <= (voltage => v_y, resistance => R_OUT, flags => AFL_KNOWN);
        Y_cap <= C_Y;
        if vdd_v > 0.01 then
          VDD_drv <= (voltage => 0.0,
                      resistance => vdd_v / (i_supply + 1.0e-12),
                      flags => AFL_KNOWN);
        end if;
      end if;
    end loop;
  end process;

end architecture;
"""
    with open(out_path, "w") as f:
        f.write(vhdl)
    print(f"Wrote {out_path} ({len(vhdl)} bytes)")


# ----------------------------------------------------------------------
# Verilog-A emission — same topology as VHDL but analog process form.
# ----------------------------------------------------------------------
def emit_va(drive_nn, inv_nn, n_hid, out_path):
    def vec_lit(v):
        return "{" + ", ".join(f"{x:+.6e}" for x in v.reshape(-1)) + "}"

    # Flat weight arrays — VA stores them as `parameter real` vectors.
    def param_vec(v, name):
        flat = v.reshape(-1)
        init = ", ".join(f"{x:+.6e}" for x in flat)
        return f"  parameter real {name}[0:{len(flat)-1}] = '{{{init}}};"

    # NN forward pass as sequence of VA statements (assigns to scalar reals).
    def va_nn_forward(n_in, xs, prefix):
        lines = []
        # Build hidden activations
        for j in range(n_hid):
            terms = " + ".join(
                f"{prefix}_W1[{i*n_hid+j}] * {xs[i]}"
                for i in range(n_in)
            )
            lines.append(f"    z_{prefix}[{j}] = {terms} + {prefix}_b1[{j}];")
            lines.append(
                f"    if (z_{prefix}[{j}] > 0.0) h_{prefix}[{j}] = z_{prefix}[{j}];"
                f" else h_{prefix}[{j}] = 0.01 * z_{prefix}[{j}];"
            )
        # Output layer
        terms = " + ".join(
            f"{prefix}_W2[{j}] * h_{prefix}[{j}]" for j in range(n_hid)
        )
        lines.append(f"    y_{prefix} = {terms} + {prefix}_b2;")
        return "\n".join(lines)

    drive_body = va_nn_forward(3, ["V(X, VSS)", "V(A, VSS)", "V(B, VSS)"], "drive")
    inv_body = va_nn_forward(2, ["V(X, VSS)", "V(Y, VSS)"], "inv")

    va = f"""// th22_nn_hybrid.va — NN currents + analytical keeper.
// Generated by extract_nn_hybrid.py. Mirrors th22_hybrid.va topology;
// two small MLPs replace the IV-table lookups.

`include "disciplines.vams"
`include "constants.vams"

module th22_nn_hybrid(A, B, Y, VDD, VSS);
  input  A, B, VDD, VSS;
  output Y;
  electrical A, B, Y, VDD, VSS;
  electrical X;

  parameter real R_KEEP = 8.0e4;
  parameter real C_X    = 6.4e-15;
  parameter real C_Y    = 5.0e-15;

{param_vec(drive_nn.W1, "drive_W1")}
{param_vec(drive_nn.b1, "drive_b1")}
{param_vec(drive_nn.W2, "drive_W2")}
  parameter real drive_b2 = {drive_nn.b2[0]:+.6e};

{param_vec(inv_nn.W1, "inv_W1")}
{param_vec(inv_nn.b1, "inv_b1")}
{param_vec(inv_nn.W2, "inv_W2")}
  parameter real inv_b2 = {inv_nn.b2[0]:+.6e};

  real z_drive[0:{n_hid-1}], h_drive[0:{n_hid-1}], y_drive;
  real z_inv  [0:{n_hid-1}], h_inv  [0:{n_hid-1}], y_inv;
  real i_drive, i_inv;

  analog begin
    // NN forward pass: drive currents (pull-up + pull-down combined)
{drive_body}
    i_drive = y_drive;

    // NN forward pass: inverter current
{inv_body}
    i_inv = y_inv;

    // KCL at X: drive + analytical keeper + cap
    I(X, VSS) <+ -(i_drive);
    I(X, VSS) <+ -(V(VDD, VSS) - V(Y, VSS) - V(X, VSS)) / R_KEEP;
    I(X, VSS) <+ C_X * ddt(V(X, VSS));

    // KCL at Y: inverter + cap
    I(Y, VSS) <+ -(i_inv);
    I(Y, VSS) <+ C_Y * ddt(V(Y, VSS));
  end
endmodule
"""
    with open(out_path, "w") as f:
        f.write(va)
    print(f"Wrote {out_path} ({len(va)} bytes)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("gate", choices=list(GATES), help="gate name")
    args = ap.parse_args()
    gate = args.gate
    n_in = GATES[gate]["n_in"]

    tables = ensure_tables(gate)
    pu = tables["pu"]
    pd = tables["pd"]
    # Inverter table: TH22 has it cached; other gates reuse TH22's
    # inverter network identically (same MPY/MNY sizing).
    th22_cache = GATES["th22"]["cache"]
    if "inv" in tables.files:
        inv = tables["inv"]
    elif os.path.exists(th22_cache):
        inv = np.load(th22_cache)["inv"]
    else:
        print("No inverter table — run characterize_th22_subnets.py first",
              file=sys.stderr)
        sys.exit(1)

    print(f"[1/3] Build training sets for {gate}")
    Xd, Yd = build_drive_dataset(pu, pd, n_in, tables)
    # Build inv dataset from inv table. Reuse TH22's inv table (same for
    # all gates since inverter sizing is identical) — need its own VDD
    # axis so reload th22 cache if inv came from a table without one.
    if "vdd_list" in tables.files and "inv" in tables.files:
        inv_tables = tables
    else:
        inv_tables = np.load(th22_cache)
    Xi, Yi = build_inv_dataset(inv_tables["inv"], inv_tables)
    Yd_s = Yd * I_SCALE
    Yi_s = Yi * I_SCALE
    print(f"  drive: X {Xd.shape}, Y {Yd_s.shape}  (|Y|max={np.abs(Yd_s).max():.2e})")
    print(f"  inv  : X {Xi.shape}, Y {Yi_s.shape}  (|Y|max={np.abs(Yi_s).max():.2e})")

    # Hidden width: the input space is now (VDD, V_X, V_a, ..., V_n) —
    # n_in+2 dimensions. Need much more capacity than the single-VDD
    # version (was 10–14 hidden). 32+ neurons with more epochs.
    n_hid = 32 + 8 * (n_in - 2)

    print("[2/3] Train drive NN")
    drive_nn = MLP(n_in=2 + n_in, n_hid=n_hid, seed=7)
    drive_nn.train(Xd, Yd_s, lr=3e-3, target_mse=1e-4,
                   max_epochs=15000, batch=64, patience=1500)
    rescale(drive_nn)

    yp = drive_nn.forward(Xd).reshape(-1)
    err = np.abs(yp - Yd.reshape(-1))
    print(f"  drive residual: mean={err.mean():.2e}A, max={err.max():.2e}A")

    print("[2/3] Train inverter NN")
    inv_nn = MLP(n_in=3, n_hid=24, seed=11)
    inv_nn.train(Xi, Yi_s, lr=3e-3, target_mse=1e-4,
                 max_epochs=15000, batch=32, patience=1500)
    rescale(inv_nn)

    yp = inv_nn.forward(Xi).reshape(-1)
    err = np.abs(yp - Yi.reshape(-1))
    print(f"  inv residual: mean={err.mean():.2e}A, max={err.max():.2e}A")

    print("[3/3] Emit cells")
    vhdl_path = os.path.join(ASIC, "cells", f"{gate}_nn_hybrid.vhd")
    va_path = os.path.join(ASIC, "cells", f"{gate}_nn_hybrid.va")
    emit_vhdl(gate, drive_nn, inv_nn, n_hid, vhdl_path)
    # VA emission is TH22-specific for now; skip for other gates.
    if gate == "th22":
        emit_va(drive_nn, inv_nn, n_hid, va_path)


if __name__ == "__main__":
    main()
