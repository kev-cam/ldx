#!/usr/bin/env python3
"""
ldx_accel_scan.py — Scan C source for FPGA-accelerable functions.

Finds functions that c2v can convert, verifies them through simulation,
and produces a manifest of available accelerators.

Usage:
    # Scan a source file for convertible functions
    python3 ldx_accel_scan.py scan mycode.c

    # Scan and verify all candidates through iverilog
    python3 ldx_accel_scan.py verify mycode.c

    # Scan, verify, and estimate speedup
    python3 ldx_accel_scan.py estimate mycode.c

    # Generate accelerator manifest (JSON)
    python3 ldx_accel_scan.py manifest mycode.c -o accel.json

Pipeline:
    1. Parse C source with libclang
    2. For each function, check if c2v can convert it (no pointers, no I/O,
       bounded loops, scalar args/return)
    3. Convert with c2v → Verilog
    4. Simulate with iverilog → verify correctness
    5. Analyze Verilog for gate complexity / critical path depth
    6. Emit manifest: {function, args, verilog, verified, gates, depth}
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import shutil

sys.path.insert(0, os.path.dirname(__file__))
from c2v import parse_and_convert, type_width, is_signed


# ---- Scan: find convertible functions ----

def scan_functions(source_file, extra_args=None):
    """Find all functions in source_file that c2v might convert."""
    import clang.cindex
    CursorKind = clang.cindex.CursorKind

    idx = clang.cindex.Index.create()
    args = ['-x', 'c', '-std=c11']
    if extra_args:
        args.extend(extra_args)
    tu = idx.parse(source_file, args=args)

    candidates = []
    for cursor in tu.cursor.get_children():
        if (cursor.kind == CursorKind.FUNCTION_DECL and
                cursor.is_definition() and
                cursor.location.file and
                os.path.abspath(cursor.location.file.name) == os.path.abspath(source_file)):

            name = cursor.spelling
            ret_type = cursor.result_type.spelling
            params = []
            for p in cursor.get_arguments():
                params.append((p.spelling, p.type.spelling))

            # Quick eligibility check
            reasons = check_eligibility(cursor, ret_type, params)

            candidates.append({
                'name': name,
                'return_type': ret_type,
                'params': [(n, t) for n, t in params],
                'signature': f"{ret_type} {name}({', '.join(t for _, t in params)})",
                'eligible': len(reasons) == 0,
                'reject_reasons': reasons,
                'line': cursor.location.line,
            })

    return candidates


def check_eligibility(cursor, ret_type, params):
    """Quick check if a function is likely convertible by c2v."""
    reasons = []

    # Check return type
    if '*' in ret_type or ret_type == 'void':
        reasons.append(f"unsupported return type: {ret_type}")

    # Check params
    for name, ptype in params:
        if '*' in ptype:
            reasons.append(f"pointer param: {ptype} {name}")

    # Check for function calls that can't be synthesized
    import clang.cindex
    CursorKind = clang.cindex.CursorKind

    def walk(node):
        if node.kind == CursorKind.CALL_EXPR:
            callee = node.spelling
            # Allow some known-convertible patterns
            if callee and callee not in ('__builtin_popcount',):
                reasons.append(f"function call: {callee}()")
        for child in node.get_children():
            walk(child)

    body = None
    for child in cursor.get_children():
        if child.kind == CursorKind.COMPOUND_STMT:
            body = child
            break

    if body:
        walk(body)
    else:
        reasons.append("no function body")

    if not params:
        reasons.append("no parameters (nothing to compute)")

    return reasons


# ---- Convert: run c2v ----

def try_convert(source_file, func_name, extra_args=None):
    """Try to convert a function with c2v. Returns (verilog, params, ret_width) or None."""
    try:
        result = parse_and_convert(source_file, func_name, extra_args)
        if result is None:
            return None
        verilog, warnings, params, ret_width = result
        return {
            'verilog': verilog,
            'params': params,
            'ret_width': ret_width,
            'warnings': warnings,
        }
    except Exception as e:
        return None


# ---- Verify: simulate with iverilog ----

def verify_with_iverilog(source_file, func_name, verilog, params, ret_width):
    """Verify c2v output by comparing against C original using iverilog."""
    workdir = tempfile.mkdtemp(prefix=f"ldx_verify_{func_name}_")

    try:
        # Write the c2v Verilog
        verilog_file = os.path.join(workdir, f"{func_name}.v")
        with open(verilog_file, 'w') as f:
            f.write(verilog + "\n")

        # Generate testbench
        tb_file = os.path.join(workdir, "tb.v")
        tb = gen_iverilog_testbench(func_name, params, ret_width)
        with open(tb_file, 'w') as f:
            f.write(tb)

        # Compile C source to get reference values
        c_obj = os.path.join(workdir, "ref.o")
        ref_prog = os.path.join(workdir, "gen_ref")
        ref_c = os.path.join(workdir, "gen_ref.c")
        ref_dat = os.path.join(workdir, "ref.dat")

        # Generate a C program that prints reference results
        ref_code = gen_reference_program(source_file, func_name, params, ret_width)
        with open(ref_c, 'w') as f:
            f.write(ref_code)

        r = subprocess.run(
            ["gcc", "-O2", "-o", ref_prog, ref_c, os.path.abspath(source_file), "-lm"],
            capture_output=True, text=True)
        if r.returncode != 0:
            return {'verified': False, 'error': f"gcc: {r.stderr.strip()}"}

        r = subprocess.run([ref_prog], capture_output=True, text=True)
        if r.returncode != 0:
            return {'verified': False, 'error': f"ref program failed"}

        ref_results = [int(line.strip(), 16) for line in r.stdout.strip().split('\n') if line.strip()]

        # Write reference data for iverilog testbench
        with open(ref_dat, 'w') as f:
            for v in ref_results:
                f.write(f"{v:08x}\n")

        # Compile and run iverilog testbench
        sim_out = os.path.join(workdir, "sim")
        r = subprocess.run(
            ["iverilog", "-o", sim_out, "-g2012",
             f"-DREF_FILE=\"{ref_dat}\"",
             f"-DNUM_TESTS={len(ref_results)}",
             tb_file, verilog_file],
            capture_output=True, text=True)
        if r.returncode != 0:
            return {'verified': False, 'error': f"iverilog: {r.stderr.strip()}"}

        r = subprocess.run(["vvp", sim_out], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return {'verified': False, 'error': f"simulation failed", 'output': r.stdout}

        # Check results — look for "ALL PASS" from the testbench
        passed = "ALL PASS" in r.stdout
        # Count individual FAIL lines (start with "FAIL:")
        n_fail = sum(1 for line in r.stdout.split('\n') if line.strip().startswith("FAIL"))
        # Extract pass count from summary line "N PASS, M FAIL"
        import re as _re
        m = _re.search(r'(\d+) PASS', r.stdout)
        n_pass = int(m.group(1)) if m else 0

        return {
            'verified': passed and n_fail == 0,
            'n_pass': n_pass,
            'n_fail': n_fail,
            'output': r.stdout.strip(),
        }

    except subprocess.TimeoutExpired:
        return {'verified': False, 'error': 'simulation timeout'}
    except Exception as e:
        return {'verified': False, 'error': str(e)}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def gen_test_vectors(params):
    """Generate test vectors for each parameter.
    params: list of (name, width, signed) from c2v."""
    def vals_for_width(width):
        if width <= 8:
            return [0, 1, 127, 255]
        if width <= 16:
            return [0, 1, 1000, 0xFFFF]
        if width <= 32:
            return [0, 1, 42, 0xDEADBEEF, 0x7FFFFFFF]
        return [0, 1, 42, 0xDEADBEEFCAFE]

    vectors = []
    param_vals = [vals_for_width(w)[:3] for _, w, _ in params]

    def gen(idx, combo):
        if idx == len(params):
            vectors.append(list(combo))
            return
        for v in param_vals[idx]:
            gen(idx + 1, combo + [v])

    gen(0, [])
    return vectors


def width_to_ctype(width, signed):
    """Convert bit width to C type string."""
    if signed:
        if width <= 8: return "int8_t"
        if width <= 16: return "int16_t"
        if width <= 32: return "int32_t"
        return "int64_t"
    else:
        if width <= 8: return "uint8_t"
        if width <= 16: return "uint16_t"
        if width <= 32: return "uint32_t"
        return "uint64_t"


def gen_reference_program(source_file, func_name, params, ret_width):
    """Generate a C program that prints reference results for test vectors.
    params: list of (name, width, signed) from c2v."""
    lines = []
    lines.append('#include <stdio.h>')
    lines.append('#include <stdint.h>')

    param_types = ", ".join(width_to_ctype(w, s) for _, w, s in params)
    ret_type = width_to_ctype(ret_width, False)
    lines.append(f'extern {ret_type} {func_name}({param_types});')
    lines.append('')
    lines.append('int main() {')

    # Use 16-hex-digit format for 64-bit returns, 8 for 32-bit
    fmt = "%016llx" if ret_width > 32 else "%08llx"
    vectors = gen_test_vectors(params)
    for vec in vectors:
        args = ", ".join(f"({width_to_ctype(w, s)}){v}ULL" for (_, w, s), v in zip(params, vec))
        lines.append(f'    printf("{fmt}\\n", (unsigned long long){func_name}({args}));')

    lines.append('    return 0;')
    lines.append('}')
    return '\n'.join(lines)


def gen_iverilog_testbench(func_name, params, ret_width):
    """Generate an iverilog testbench that checks against reference data."""
    lines = []
    lines.append('`timescale 1ns/1ps')
    lines.append(f'module tb_{func_name};')

    # Declare inputs/outputs
    for i, (name, width, signed) in enumerate(params):
        sign = "signed " if signed else ""
        lines.append(f'  reg {sign}[{width-1}:0] {name};')
    lines.append(f'  wire [{ret_width-1}:0] result;')
    lines.append('')

    # Instantiate DUT
    ports = ", ".join(f'.{name}({name})' for name, _, _ in params)
    lines.append(f'  {func_name} dut({ports}, .result(result));')
    lines.append('')

    # Test logic
    vectors = gen_test_vectors(params)
    lines.append('  integer pass = 0, fail = 0;')
    lines.append(f'  reg [{ret_width-1}:0] expected;')
    lines.append(f'  reg [{ret_width-1}:0] ref_data [0:{len(vectors)-1}];')
    lines.append('')
    lines.append('  initial begin')
    lines.append('    $readmemh(`REF_FILE, ref_data);')

    for idx, vec in enumerate(vectors):
        for i, (name, _, _) in enumerate(params):
            lines.append(f'    {name} = {vec[i]};')
        lines.append(f'    expected = ref_data[{idx}];')
        lines.append(f'    #1;')
        lines.append(f'    if (result === expected) pass = pass + 1;')
        lines.append(f'    else begin fail = fail + 1;')
        lines.append(f'      $display("FAIL: result=%h expected=%h", result, expected);')
        lines.append(f'    end')

    lines.append(f'    $display("%0d PASS, %0d FAIL", pass, fail);')
    lines.append(f'    if (fail == 0) $display("ALL PASS");')
    lines.append('    $finish;')
    lines.append('  end')
    lines.append('endmodule')
    return '\n'.join(lines)


# ---- Estimate: analyze Verilog complexity ----

def estimate_complexity(verilog, params, ret_width):
    """Estimate gate count and critical path depth from Verilog source."""
    # Count operations as a rough gate estimate
    ops = {
        'add': len(re.findall(r'[^<>!]=?\+', verilog)),
        'sub': len(re.findall(r'[^-]-(?!>)', verilog)),
        'mul': len(re.findall(r'\*', verilog)),
        'mux': len(re.findall(r'\?', verilog)),
        'and': len(re.findall(r'&(?!&)', verilog)),
        'or':  len(re.findall(r'\|(?!\|)', verilog)),
        'xor': len(re.findall(r'\^', verilog)),
        'not': len(re.findall(r'~', verilog)),
        'shift': len(re.findall(r'<<|>>', verilog)),
        'compare': len(re.findall(r'[<>]=?|[!=]=', verilog)),
    }

    # Very rough gate estimate: each op ≈ width gates
    max_width = max([w for _, w, _ in params] + [ret_width])
    total_ops = sum(ops.values())
    est_gates = total_ops * max_width

    # Count assign statements as rough depth proxy
    n_assigns = len(re.findall(r'assign\s', verilog))
    n_wires = len(re.findall(r'wire\s', verilog))

    # Count lines as complexity proxy
    n_lines = len([l for l in verilog.split('\n') if l.strip() and not l.strip().startswith('//')])

    # Estimate combinational delay: each MUX/compare adds ~1 level
    est_depth = ops['mux'] + ops['compare'] + (1 if ops['mul'] > 0 else 0)

    # PCIe round-trip overhead (BAR write + BAR read ≈ 1-2 µs on Gen1 x1)
    # Function must save more than this to be worth accelerating
    pcie_overhead_ns = 1500  # conservative: 1.5 µs

    # FPGA clock period (125 MHz core clock = 8ns)
    fpga_period_ns = 8
    fpga_cycles = max(1, est_depth)
    fpga_time_ns = fpga_cycles * fpga_period_ns

    return {
        'ops': ops,
        'total_ops': total_ops,
        'est_gates': est_gates,
        'est_depth': est_depth,
        'n_lines': n_lines,
        'fpga_time_ns': fpga_time_ns,
        'pcie_overhead_ns': pcie_overhead_ns,
        'total_fpga_ns': fpga_time_ns + pcie_overhead_ns,
        'break_even_cpu_ns': fpga_time_ns + pcie_overhead_ns,
        'note': 'Accelerating is worthwhile when CPU time > break_even_cpu_ns per call, '
                'or when batching many calls amortizes the PCIe overhead.',
    }


# ---- Manifest: produce JSON output ----

def build_manifest(source_file, verify=False, estimate=False, extra_args=None, verbose=False):
    """Scan, optionally verify and estimate, return manifest."""
    candidates = scan_functions(source_file, extra_args)

    manifest = {
        'source': os.path.abspath(source_file),
        'functions': [],
    }

    for cand in candidates:
        entry = {
            'name': cand['name'],
            'signature': cand['signature'],
            'line': cand['line'],
            'eligible': cand['eligible'],
        }

        if not cand['eligible']:
            entry['reject_reasons'] = cand['reject_reasons']
            manifest['functions'].append(entry)
            continue

        # Try conversion
        if verbose:
            print(f"  Converting {cand['name']}...", file=sys.stderr)
        result = try_convert(source_file, cand['name'], extra_args)

        if result is None:
            entry['converted'] = False
            entry['reject_reasons'] = ['c2v conversion failed']
            manifest['functions'].append(entry)
            continue

        entry['converted'] = True
        entry['n_params'] = len(result['params'])
        entry['ret_width'] = result['ret_width']
        entry['warnings'] = result['warnings']
        entry['verilog_lines'] = len(result['verilog'].split('\n'))

        # Verify
        if verify:
            if verbose:
                print(f"  Verifying {cand['name']}...", file=sys.stderr)
            vresult = verify_with_iverilog(
                source_file, cand['name'],
                result['verilog'], result['params'], result['ret_width'])
            entry['verified'] = vresult.get('verified', False)
            entry['verify_detail'] = vresult

        # Estimate
        if estimate:
            est = estimate_complexity(
                result['verilog'], result['params'], result['ret_width'])
            entry['estimate'] = est

        manifest['functions'].append(entry)

    # Summary
    n_eligible = sum(1 for f in manifest['functions'] if f.get('eligible'))
    n_converted = sum(1 for f in manifest['functions'] if f.get('converted'))
    n_verified = sum(1 for f in manifest['functions'] if f.get('verified'))

    manifest['summary'] = {
        'total': len(manifest['functions']),
        'eligible': n_eligible,
        'converted': n_converted,
        'verified': n_verified,
    }

    return manifest


# ---- CLI ----

def main():
    parser = argparse.ArgumentParser(
        description="Scan C source for FPGA-accelerable functions",
    )
    parser.add_argument("mode", choices=["scan", "verify", "estimate", "manifest"],
                        help="scan: find candidates; verify: + iverilog check; "
                             "estimate: + complexity analysis; manifest: + JSON output")
    parser.add_argument("input", help="C source file")
    parser.add_argument("-o", "--output", help="Output JSON file (manifest mode)")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("-I", action="append", default=[], help="Include path")
    args = parser.parse_args()

    extra = [f"-I{d}" for d in args.I]

    do_verify = args.mode in ("verify", "estimate", "manifest")
    do_estimate = args.mode in ("estimate", "manifest")

    manifest = build_manifest(args.input, verify=do_verify, estimate=do_estimate,
                              extra_args=extra, verbose=args.verbose)

    if args.mode == "scan":
        # Simple text output
        print(f"Source: {args.input}")
        print(f"Found {manifest['summary']['total']} functions, "
              f"{manifest['summary']['eligible']} eligible for FPGA")
        print()
        for f in manifest['functions']:
            status = "OK" if f.get('eligible') else "SKIP"
            print(f"  [{status:4s}] {f['signature']}")
            if not f.get('eligible'):
                for r in f.get('reject_reasons', []):
                    print(f"         → {r}")

    elif args.mode in ("verify", "estimate"):
        print(f"Source: {args.input}")
        s = manifest['summary']
        print(f"Functions: {s['total']} total, {s['eligible']} eligible, "
              f"{s['converted']} converted, {s.get('verified', '?')} verified")
        print()
        for f in manifest['functions']:
            if not f.get('converted'):
                status = "SKIP"
            elif f.get('verified'):
                status = "PASS"
            elif 'verified' in f:
                status = "FAIL"
            else:
                status = " OK "
            line = f"  [{status}] {f['name']}"
            if f.get('estimate'):
                est = f['estimate']
                line += f"  ({est['total_ops']} ops, ~{est['est_gates']} gates, "
                line += f"depth {est['est_depth']}, "
                line += f"break-even >{est['break_even_cpu_ns']}ns/call)"
            print(line)
            if f.get('verify_detail', {}).get('error'):
                print(f"         error: {f['verify_detail']['error']}")

    elif args.mode == "manifest":
        output = json.dumps(manifest, indent=2)
        if args.output:
            with open(args.output, 'w') as f:
                f.write(output + "\n")
            print(f"Wrote {args.output}", file=sys.stderr)
        else:
            print(output)


if __name__ == "__main__":
    main()
