#!/usr/bin/env python3
"""Generate NCL 4-phase testbenches for combinational cells.

For each test vector we drive a NULL→DATA→NULL cycle, sampling outputs at
the end of the DATA phase and checking the NULL phase returns outputs to 0.
"""

import itertools, os

VDD = 1.2
DATA_NS = 12
NULL_NS = 12
EDGE_PS = 50
CWD = os.path.dirname(os.path.abspath(__file__))

HEADER = ""
MODELS = [
    f'.include "/tmp/sg13g2_models.lib"',
    f'.include "/usr/local/src/ldx/asic/cells/th22.sp"',
    f'.include "/usr/local/src/ldx/asic/cells/th_gates.sp"',
    f'.include "/usr/local/src/ldx/asic/cells/ncl_logic.sp"',
    f'.include "/usr/local/src/ldx/asic/cells/nclfa.sp"',
    f'.include "/usr/local/src/ldx/asic/cells/nclfa4.sp"',
]

def pwl_lines(name, cases, value_fn):
    """Emit a PWL source for a single rail named <name>.
    value_fn(case_index) -> 0 or 1 — rail value during DATA phase of that case."""
    pts = [(0.0, 0)]
    for k, _ in enumerate(cases):
        t_data_start = k * (NULL_NS + DATA_NS) + NULL_NS
        t_data_end = t_data_start + DATA_NS
        hi = value_fn(k)
        pts.append((t_data_start - EDGE_PS / 1000, 0))
        pts.append((t_data_start + EDGE_PS / 1000, VDD if hi else 0))
        pts.append((t_data_end - EDGE_PS / 1000, VDD if hi else 0))
        pts.append((t_data_end + EDGE_PS / 1000, 0))
    pts.append((10_000, 0))
    out = [f"V{name} {name} 0 PWL"]
    for t_ns, v in pts:
        out.append(f"+ {t_ns:.3f}n {v}")
    return "\n".join(out)

def dual_rail_pwls(names_bits, cases):
    """For each (rail_basename, bit_extractor) emit H and L PWL.
    cases is a list of tuples; bit_extractor takes a case tuple -> 0/1."""
    lines = []
    for base, extract in names_bits:
        lines.append(pwl_lines(f"{base}H", cases, lambda k, e=extract: e(cases[k])))
        lines.append(pwl_lines(f"{base}L", cases, lambda k, e=extract: 1 - e(cases[k])))
    return "\n".join(lines)

def case_data_window_end(k):
    return (k * (NULL_NS + DATA_NS) + NULL_NS + DATA_NS)

def case_null_middle(k):
    # Mid-point of the NULL phase after case k
    t_null_start = case_data_window_end(k)
    return t_null_start + NULL_NS / 2

def emit_tb(filename, dut_subckt, inputs, outputs, cases, expected_fn, comment):
    """inputs: [(name, extract_fn)] — dual-rail input signals
    outputs: [name] — dual-rail output signals (H/L suffix added)
    cases: list of input-tuple test vectors
    expected_fn(case_tuple) -> dict {output_name: 0|1}"""
    n_cases = len(cases)
    sim_end_ns = n_cases * (NULL_NS + DATA_NS) + NULL_NS

    hdr = [f"* {filename} — {comment}"]
    hdr.append("*")
    hdr.append(f"* {n_cases} cases, DATA={DATA_NS}ns NULL={NULL_NS}ns")
    hdr.append("")
    hdr.extend(MODELS)
    hdr.append("")
    hdr.append(f"VVDD VDD 0 {VDD}")
    hdr.append("VVSS VSS 0 0")
    hdr.append("")
    hdr.append(dual_rail_pwls(inputs, cases))
    hdr.append("")

    # Instantiate DUT — assume port order is inH0 inL0 inH1 inL1 ... outH0 outL0 ...
    dut_ports = []
    for base, _ in inputs:
        dut_ports += [f"{base}H", f"{base}L"]
    for base in outputs:
        dut_ports += [f"{base}H", f"{base}L"]
    dut_ports += ["VDD", "VSS"]
    hdr.append(f"Xdut {' '.join(dut_ports)} {dut_subckt}")
    hdr.append("")

    # Output loads
    for base in outputs:
        hdr.append(f"CL{base}H {base}H 0 3f")
        hdr.append(f"CL{base}L {base}L 0 3f")
    hdr.append("")

    hdr.append(f".tran 20p {sim_end_ns}n")
    probe = " ".join(f"V({b}H) V({b}L)" for b, _ in inputs) + " " + \
            " ".join(f"V({b}H) V({b}L)" for b in outputs)
    hdr.append(f".print tran format=csv {probe}")
    hdr.append(".options timeint method=gear")
    hdr.append(".end")

    with open(os.path.join(CWD, filename), "w") as f:
        f.write("\n".join(hdr) + "\n")

    # Also write an .expected file for the checker
    with open(os.path.join(CWD, filename + ".expected"), "w") as f:
        f.write(f"# case_index, {','.join(f'in_{b}' for b,_ in inputs)}, "
                f"{','.join(f'out_{b}' for b in outputs)}, sample_ns\n")
        for k, c in enumerate(cases):
            e = expected_fn(c)
            in_vals = ",".join(str(extract(c)) for _, extract in inputs)
            out_vals = ",".join(str(e[b]) for b in outputs)
            sample_ns = case_data_window_end(k) - 1
            f.write(f"{k},{in_vals},{out_vals},{sample_ns}\n")

    print(f"Wrote {filename} ({sim_end_ns} ns, {n_cases} cases)")

# ---------- XOR2 ----------
emit_tb(
    "tb_xor2.sp", "ncl_xor2",
    inputs=[("a", lambda c: c[0]), ("b", lambda c: c[1])],
    outputs=["y"],
    cases=list(itertools.product([0, 1], repeat=2)),
    expected_fn=lambda c: {"y": c[0] ^ c[1]},
    comment="dual-rail XOR2, 4 cases",
)

# ---------- Ch (SHA-256 choose) ----------
emit_tb(
    "tb_ch.sp", "ncl_ch",
    inputs=[("e", lambda c: c[0]), ("f", lambda c: c[1]), ("g", lambda c: c[2])],
    outputs=["y"],
    cases=list(itertools.product([0, 1], repeat=3)),
    expected_fn=lambda c: {"y": (c[0] & c[1]) | ((1 - c[0]) & c[2])},
    comment="SHA-256 Ch(e,f,g) = (e·f) | (!e·g), 8 cases",
)

# ---------- Maj3 ----------
emit_tb(
    "tb_maj3.sp", "ncl_maj3",
    inputs=[("a", lambda c: c[0]), ("b", lambda c: c[1]), ("c", lambda c: c[2])],
    outputs=["y"],
    cases=list(itertools.product([0, 1], repeat=3)),
    expected_fn=lambda c: {"y": 1 if sum(c) >= 2 else 0},
    comment="dual-rail Maj3(a,b,c), 8 cases",
)

# ---------- 4-bit adder ----------
# Test a curated set to keep sim time bounded: 0+0, 1+1, 5+3, 7+9, 15+15, 8+7
adder_cases = [(0, 0), (1, 1), (5, 3), (7, 9), (8, 7), (15, 15)]

def bit(x, i): return (x >> i) & 1

emit_tb(
    "tb_adder4.sp", "nclfa4",
    inputs=[
        ("a0", lambda c: bit(c[0], 0)), ("a1", lambda c: bit(c[0], 1)),
        ("a2", lambda c: bit(c[0], 2)), ("a3", lambda c: bit(c[0], 3)),
        ("b0", lambda c: bit(c[1], 0)), ("b1", lambda c: bit(c[1], 1)),
        ("b2", lambda c: bit(c[1], 2)), ("b3", lambda c: bit(c[1], 3)),
        ("ci", lambda c: 0),
    ],
    outputs=["s0", "s1", "s2", "s3", "co"],
    cases=adder_cases,
    expected_fn=lambda c: {
        "s0": bit(c[0] + c[1], 0), "s1": bit(c[0] + c[1], 1),
        "s2": bit(c[0] + c[1], 2), "s3": bit(c[0] + c[1], 3),
        "co": bit(c[0] + c[1], 4),
    },
    comment="4-bit NCL ripple adder, 6 cases",
)
