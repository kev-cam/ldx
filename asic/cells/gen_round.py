#!/usr/bin/env python3
"""Generate a SHA-256-style NCL round at configurable bit-width.

Emits:
  round_<W>.sp  — structural netlist of the round
  round_<W>_tb.sp — testbench with one vector
  round_<W>_expected.json — software-computed expected output

Round definition (simplified to two outputs a_new, e_new):
  T1 = h + Σ1(e) + Ch(e,f,g)            -- 3 inputs, 2 sequential adds
  T2 = Σ0(a) + Maj(a,b,c)                -- 2 inputs, 1 add
  a_new = T1 + T2                         -- 1 add
  e_new = d + T1                          -- 1 add (parallel with a_new)

Real SHA-256 has additional + K and + W terms and uses 32-bit rotations;
we parameterise width W and pick 3 distinct rotations that scale down for
structural testing.
"""

import argparse, json, os, sys

CWD = os.path.dirname(os.path.abspath(__file__))

# ---- rotation schedules (scale from SHA-256 (2,13,22) / (6,11,25)) ----
def rot_sched(w):
    if w >= 8:
        # Pick three distinct within [1, w-1]
        return (2, max(3, w // 3), max(5, 2 * w // 3))
    else:
        # 4-bit: (1,2,3) distinct
        return (1, 2, 3)

# ---- software reference for verification ----
def mask(w):
    return (1 << w) - 1

def rotr(x, n, w):
    n %= w
    return ((x >> n) | (x << (w - n))) & mask(w)

def sha_round(a, b, c, d, e, f, g, h, w):
    s0r = rot_sched(w)
    s1r = rot_sched(w)[::-1]  # different rotations for Σ1
    M = mask(w)
    S0 = rotr(a, s0r[0], w) ^ rotr(a, s0r[1], w) ^ rotr(a, s0r[2], w)
    S1 = rotr(e, s1r[0], w) ^ rotr(e, s1r[1], w) ^ rotr(e, s1r[2], w)
    ch = ((e & f) | ((~e) & g)) & M
    mj = (a & b) | (a & c) | (b & c)
    T1 = (h + S1 + ch) & M
    T2 = (S0 + mj) & M
    a_new = (T1 + T2) & M
    e_new = (d + T1) & M
    return a_new, e_new, {
        "S0": S0, "S1": S1, "ch": ch, "mj": mj,
        "T1": T1, "T2": T2, "a_new": a_new, "e_new": e_new,
    }

# ---- netlist helpers ----
def dr_ports(name, w):
    """Return [name0H name0L ... nameWH nameWL]"""
    return [f"{name}{i}{c}" for i in range(w) for c in "HL"]

def emit_sigma(w, rot, name):
    """Σ-function: y[i] = x[(i+r0)%w] ^ x[(i+r1)%w] ^ x[(i+r2)%w]"""
    lines = [f"* Σ {name}: rotations {rot}"]
    header = [f".subckt {name}"] + dr_ports("x", w) + dr_ports("y", w) + ["VDD", "VSS"]
    lines.append(" ".join(header))
    for i in range(w):
        j0 = (i + rot[0]) % w
        j1 = (i + rot[1]) % w
        j2 = (i + rot[2]) % w
        lines.append(
            f"Xx{i} x{j0}H x{j0}L x{j1}H x{j1}L x{j2}H x{j2}L "
            f"y{i}H y{i}L VDD VSS ncl_xor3"
        )
    lines.append(".ends")
    return "\n".join(lines)

def emit_ch(w):
    lines = [f".subckt ch_{w}"]
    hdr = [f".subckt ch_{w}"] + dr_ports("e", w) + dr_ports("f", w) + \
          dr_ports("g", w) + dr_ports("y", w) + ["VDD", "VSS"]
    out = [" ".join(hdr)]
    for i in range(w):
        out.append(
            f"Xc{i} e{i}H e{i}L f{i}H f{i}L g{i}H g{i}L y{i}H y{i}L VDD VSS ncl_ch"
        )
    out.append(".ends")
    return "\n".join(out)

def emit_maj(w):
    hdr = [f".subckt maj_{w}"] + dr_ports("a", w) + dr_ports("b", w) + \
          dr_ports("c", w) + dr_ports("y", w) + ["VDD", "VSS"]
    out = [" ".join(hdr)]
    for i in range(w):
        out.append(
            f"Xm{i} a{i}H a{i}L b{i}H b{i}L c{i}H c{i}L y{i}H y{i}L VDD VSS ncl_maj3"
        )
    out.append(".ends")
    return "\n".join(out)

def emit_adder(w):
    """N-bit ripple adder using nclfa, with externally supplied ciH/ciL."""
    hdr = [f".subckt add_{w}"] + dr_ports("a", w) + dr_ports("b", w) + \
          ["ciH", "ciL"] + dr_ports("s", w) + ["coH", "coL", "VDD", "VSS"]
    out = [" ".join(hdr)]
    for i in range(w):
        ciH = "ciH" if i == 0 else f"c{i}H"
        ciL = "ciL" if i == 0 else f"c{i}L"
        if i == w - 1:
            coH, coL = "coH", "coL"
        else:
            coH, coL = f"c{i+1}H", f"c{i+1}L"
        out.append(
            f"Xfa{i} a{i}H a{i}L b{i}H b{i}L {ciH} {ciL} "
            f"s{i}H s{i}L {coH} {coL} VDD VSS nclfa"
        )
    out.append(".ends")
    return "\n".join(out)

def emit_round(w):
    """Top-level round: 8 inputs (a..h), outputs a_new, e_new."""
    rot = rot_sched(w)
    rot_s1 = rot[::-1]

    lines = [f"* SHA-style NCL round, width={w}, Σ0 rot={rot}, Σ1 rot={rot_s1}"]
    lines.append(emit_sigma(w, rot, "sigma0"))
    lines.append(emit_sigma(w, rot_s1, "sigma1"))
    lines.append(emit_ch(w))
    lines.append(emit_maj(w))
    lines.append(emit_adder(w))

    # Round top
    hdr = [f".subckt sha_round_{w}"] + \
          dr_ports("a", w) + dr_ports("b", w) + dr_ports("c", w) + dr_ports("d", w) + \
          dr_ports("e", w) + dr_ports("f", w) + dr_ports("g", w) + dr_ports("h", w) + \
          ["cinH", "cinL"] + \
          dr_ports("an", w) + dr_ports("en", w) + \
          ["VDD", "VSS"]
    body = [" ".join(hdr)]

    # Σ0(a), Σ1(e)
    body.append("* Σ0(a)")
    body.append("Xs0 " + " ".join(dr_ports("a", w)) + " " +
                " ".join(dr_ports("S0_", w)) + " VDD VSS sigma0")
    body.append("* Σ1(e)")
    body.append("Xs1 " + " ".join(dr_ports("e", w)) + " " +
                " ".join(dr_ports("S1_", w)) + " VDD VSS sigma1")
    # Ch(e,f,g)
    body.append("* Ch(e,f,g)")
    body.append("Xch " + " ".join(dr_ports("e", w)) + " " +
                " ".join(dr_ports("f", w)) + " " +
                " ".join(dr_ports("g", w)) + " " +
                " ".join(dr_ports("ch_", w)) + " VDD VSS ch_" + str(w))
    # Maj(a,b,c)
    body.append("* Maj(a,b,c)")
    body.append("Xmj " + " ".join(dr_ports("a", w)) + " " +
                " ".join(dr_ports("b", w)) + " " +
                " ".join(dr_ports("c", w)) + " " +
                " ".join(dr_ports("mj_", w)) + " VDD VSS maj_" + str(w))

    # T1 = h + Σ1  (first add); then T1 += Ch
    body.append("* T1a = h + Σ1")
    body.append("Xadd1 " + " ".join(dr_ports("h", w)) + " " +
                " ".join(dr_ports("S1_", w)) + " cinH cinL " +
                " ".join(dr_ports("T1a_", w)) + " co1H co1L VDD VSS add_" + str(w))
    body.append("* T1 = T1a + Ch")
    body.append("Xadd2 " + " ".join(dr_ports("T1a_", w)) + " " +
                " ".join(dr_ports("ch_", w)) + " cinH cinL " +
                " ".join(dr_ports("T1_", w)) + " co2H co2L VDD VSS add_" + str(w))
    # T2 = Σ0 + Maj
    body.append("* T2 = Σ0 + Maj")
    body.append("Xadd3 " + " ".join(dr_ports("S0_", w)) + " " +
                " ".join(dr_ports("mj_", w)) + " cinH cinL " +
                " ".join(dr_ports("T2_", w)) + " co3H co3L VDD VSS add_" + str(w))
    # a_new = T1 + T2
    body.append("* a_new = T1 + T2")
    body.append("Xadd4 " + " ".join(dr_ports("T1_", w)) + " " +
                " ".join(dr_ports("T2_", w)) + " cinH cinL " +
                " ".join(dr_ports("an", w)) + " co4H co4L VDD VSS add_" + str(w))
    # e_new = d + T1
    body.append("* e_new = d + T1")
    body.append("Xadd5 " + " ".join(dr_ports("d", w)) + " " +
                " ".join(dr_ports("T1_", w)) + " cinH cinL " +
                " ".join(dr_ports("en", w)) + " co5H co5L VDD VSS add_" + str(w))

    body.append(".ends")
    lines.append("\n".join(body))
    return "\n\n".join(lines)

# ---- testbench ----
VDD = 1.2
DATA_NS = 60   # much longer; ~30 gate stages critical path at ~500ps each
NULL_NS = 60
EDGE_PS = 100

def pwl_rail(name, hi_during_data):
    """Emit PWL: rail at VDD during DATA phase iff hi_during_data, else 0."""
    pts = [(0.0, 0)]
    pts.append((NULL_NS - EDGE_PS / 1000, 0))
    pts.append((NULL_NS + EDGE_PS / 1000, VDD if hi_during_data else 0))
    pts.append((NULL_NS + DATA_NS - EDGE_PS / 1000, VDD if hi_during_data else 0))
    pts.append((NULL_NS + DATA_NS + EDGE_PS / 1000, 0))
    pts.append((NULL_NS * 2 + DATA_NS, 0))
    lines = [f"V{name} {name} 0 PWL"]
    for t, v in pts:
        lines.append(f"+ {t:.3f}n {v}")
    return "\n".join(lines)

def emit_testbench(w, vector):
    """vector: dict with a,b,c,d,e,f,g,h (each masked to w bits)."""
    inputs = ["a", "b", "c", "d", "e", "f", "g", "h"]
    M = mask(w)

    lines = [f"* round_{w}_tb.sp — one test vector for width={w}", "*"]
    for k in inputs:
        lines.append(f"* {k} = 0x{vector[k] & M:x}")
    lines.append("")
    a_new, e_new, inter = sha_round(
        vector["a"], vector["b"], vector["c"], vector["d"],
        vector["e"], vector["f"], vector["g"], vector["h"], w)
    lines.append(f"* Expected a_new = 0x{a_new:x}, e_new = 0x{e_new:x}")
    lines.append("")
    lines += [
        '.include "/tmp/sg13g2_models.lib"',
        '.include "/usr/local/src/ldx/asic/cells/th22.sp"',
        '.include "/usr/local/src/ldx/asic/cells/th_gates.sp"',
        '.include "/usr/local/src/ldx/asic/cells/ncl_logic.sp"',
        '.include "/usr/local/src/ldx/asic/cells/ncl_xor3.sp"',
        '.include "/usr/local/src/ldx/asic/cells/nclfa.sp"',
        f'.include "/usr/local/src/ldx/asic/cells/round_{w}.sp"',
        "",
        f"VVDD VDD 0 {VDD}",
        "VVSS VSS 0 0",
        "",
    ]
    # Input PWLs
    for k in inputs:
        val = vector[k] & M
        for i in range(w):
            bit = (val >> i) & 1
            lines.append(pwl_rail(f"{k}{i}H", bit == 1))
            lines.append(pwl_rail(f"{k}{i}L", bit == 0))
    # Cin = 0 (data0: ciH=0, ciL=VDD during DATA)
    lines.append(pwl_rail("cinH", False))
    lines.append(pwl_rail("cinL", True))
    lines.append("")

    # DUT
    port_list = []
    for k in inputs:
        port_list += dr_ports(k, w)
    port_list += ["cinH", "cinL"]
    port_list += dr_ports("an", w)
    port_list += dr_ports("en", w)
    port_list += ["VDD", "VSS"]
    lines.append("Xdut " + " ".join(port_list) + f" sha_round_{w}")
    lines.append("")

    # Loads
    for i in range(w):
        lines.append(f"CLan{i}H an{i}H 0 3f")
        lines.append(f"CLan{i}L an{i}L 0 3f")
        lines.append(f"CLen{i}H en{i}H 0 3f")
        lines.append(f"CLen{i}L en{i}L 0 3f")

    sim_end = NULL_NS * 2 + DATA_NS
    lines.append("")
    lines.append(f".tran 100p {sim_end}n")
    probes = " ".join(f"V(an{i}H) V(an{i}L) V(en{i}H) V(en{i}L)" for i in range(w))
    lines.append(f".print tran format=csv {probes}")
    lines.append(".options timeint method=gear")
    lines.append(".end")

    return "\n".join(lines), a_new, e_new, inter

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, default=4)
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    w = args.width
    import random
    rng = random.Random(args.seed)
    M = mask(w)
    vector = {k: rng.randint(0, M) for k in "abcdefgh"}

    # Emit round netlist
    round_sp = emit_round(w)
    with open(os.path.join(CWD, f"round_{w}.sp"), "w") as f:
        f.write(round_sp)

    # Emit testbench
    tb, a_new, e_new, inter = emit_testbench(w, vector)
    tb_path = os.path.join(CWD, "..", "tb", f"round_{w}_tb.sp")
    with open(tb_path, "w") as f:
        f.write(tb)

    # Expected
    exp_path = os.path.join(CWD, "..", "tb", f"round_{w}_expected.json")
    with open(exp_path, "w") as f:
        json.dump({"width": w, "vector": vector, "a_new": a_new, "e_new": e_new,
                   "intermediate": inter}, f, indent=2)

    # Summary
    print(f"Generated round_{w}.sp + round_{w}_tb.sp")
    print(f"Vector: {vector}")
    print(f"Expected: a_new=0x{a_new:x}  e_new=0x{e_new:x}")

if __name__ == "__main__":
    main()
