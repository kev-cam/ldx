#!/usr/bin/env python3
"""Check NCL testbench results against .expected file."""
import csv, sys, os

def decode(H, L, vth=0.6):
    if H > vth and L < vth: return 1
    if L > vth and H < vth: return 0
    if H < vth and L < vth: return 'N'
    return '?'

def check(tb):
    csv_path = tb + ".csv"
    exp_path = tb + ".expected"
    if not os.path.exists(csv_path) or not os.path.exists(exp_path):
        print(f"  SKIP {tb} (missing csv or expected)")
        return False

    with open(csv_path) as f:
        rows = list(csv.reader(f))
    hdr = rows[0]
    data = rows[1:]
    col = {name.upper(): i for i, name in enumerate(hdr)}

    def at(t):
        prev = data[0]
        for r in data:
            if float(r[0]) > t:
                return prev
            prev = r
        return prev

    with open(exp_path) as f:
        exp = [l.strip() for l in f if l.strip() and not l.startswith("#")]

    passed = failed = 0
    details = []
    for line in exp:
        parts = line.split(",")
        k = int(parts[0])
        sample_ns = float(parts[-1])
        # Remaining parts: in values then out values. We only need out names from header.
        row = at(sample_ns * 1e-9)
        rvals = {name.upper(): float(row[i]) for i, name in enumerate(hdr)}

        # Decode all output rails present in CSV (anything ending H with matching L)
        # and compare to expected row. The expected file lists outputs by pair;
        # we match by last N values where N = (total_expected_values - inputs_count).
        # Simpler: the .expected header has the output names; parse from first line of .expected.
        pass

    # Re-parse expected properly using the header line
    with open(exp_path) as f:
        lines = [l for l in f]
    header_line = lines[0].lstrip("#").strip()
    field_names = [x.strip() for x in header_line.split(",")]
    in_names = [n[3:] for n in field_names if n.startswith("in_")]
    out_names = [n[4:] for n in field_names if n.startswith("out_")]

    ok_total = True
    for line in lines[1:]:
        line = line.strip()
        if not line or line.startswith("#"): continue
        parts = [p.strip() for p in line.split(",")]
        k = int(parts[0])
        pos = 1
        in_vals = [int(parts[pos + i]) for i, _ in enumerate(in_names)]
        pos += len(in_names)
        exp_outs = [int(parts[pos + i]) for i, _ in enumerate(out_names)]
        pos += len(out_names)
        sample_ns = float(parts[pos])

        row = at(sample_ns * 1e-9)
        rvals = {name.upper(): float(row[i]) for i, name in enumerate(hdr)}

        actual = []
        for b in out_names:
            H = rvals.get(f"V({b.upper()}H)")
            L = rvals.get(f"V({b.upper()}L)")
            actual.append(decode(H, L))

        ok = all(a == e for a, e in zip(actual, exp_outs))
        if not ok:
            ok_total = False
            status = "FAIL"
        else:
            status = "ok"
        print(f"  {tb} case {k}: in={in_vals} expected={exp_outs} got={actual} [{status}]")

    # NULL check after last case
    t_last = sample_ns + 6  # mid-NULL after last DATA
    row = at(t_last * 1e-9)
    rvals = {name.upper(): float(row[i]) for i, name in enumerate(hdr)}
    null_ok = True
    for b in out_names:
        H = rvals.get(f"V({b.upper()}H)")
        L = rvals.get(f"V({b.upper()}L)")
        if not (H < 0.2 and L < 0.2):
            null_ok = False
            print(f"  {tb} NULL check: {b} H={H:.3f} L={L:.3f} — not NULL")
    if null_ok:
        print(f"  {tb} NULL spacer ok at t={t_last:.1f}ns")

    return ok_total and null_ok

if __name__ == "__main__":
    overall = True
    for tb in sys.argv[1:]:
        print(f"--- {tb} ---")
        r = check(tb)
        overall = overall and r
        print()
    sys.exit(0 if overall else 1)
