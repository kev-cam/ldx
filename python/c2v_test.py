#!/usr/bin/env python3
"""
c2v_test.py — End-to-end test: C function → Verilog → Verilator → run.

1. c2v converts a C function to Verilog
2. Generates a Verilator testbench wrapper (C++)
3. Verilator compiles Verilog → C++ model
4. Builds a shared library that exposes the same C function signature
5. Tests that the Verilator model produces identical results to the C original

Usage:
    python3 c2v_test.py test/c2v_test.c -f add
    python3 c2v_test.py test/c2v_test.c -f max --keep
    python3 c2v_test.py test/c2v_test.c -f bitwise_blend
"""

import argparse
import os
import subprocess
import sys
import tempfile
import shutil

# Add parent dir for imports
sys.path.insert(0, os.path.dirname(__file__))
from c2v import parse_and_convert, type_width, is_signed, is_floating


def gen_verilator_wrapper(module_name, params, ret_width):
    """Generate C++ wrapper that exposes the Verilator model as a C function."""

    # Determine C types for params and return
    def c_type(width, signed):
        if width <= 8: return "uint8_t" if not signed else "int8_t"
        if width <= 16: return "uint16_t" if not signed else "int16_t"
        if width <= 32: return "uint32_t" if not signed else "int32_t"
        return "uint64_t" if not signed else "int64_t"

    ret_signed = True  # TODO: get from function
    ret_ctype = c_type(ret_width, ret_signed)

    param_decls = ", ".join(f"{c_type(w, s)} {n}" for n, w, s in params)

    lines = []
    lines.append(f'#include "V{module_name}.h"')
    lines.append('#include <verilated.h>')
    lines.append('#include <cstdint>')
    lines.append('#include <cstdio>')
    lines.append('')
    lines.append(f'static V{module_name} *model = nullptr;')
    lines.append('')
    lines.append('extern "C" {')
    lines.append('')
    lines.append(f'{ret_ctype} {module_name}_hw({param_decls}) {{')
    lines.append(f'    if (!model) model = new V{module_name};')
    for name, width, signed in params:
        lines.append(f'    model->{name} = {name};')
    lines.append(f'    model->eval();')
    lines.append(f'    return model->result;')
    lines.append('}')
    lines.append('')
    lines.append('}')
    lines.append('')

    return "\n".join(lines)


def gen_test_main(module_name, params, ret_width):
    """Generate a test program that calls both C original and Verilator model."""

    def c_type(width, signed):
        if width <= 8: return "uint8_t" if not signed else "int8_t"
        if width <= 16: return "uint16_t" if not signed else "int16_t"
        if width <= 32: return "uint32_t" if not signed else "int32_t"
        return "uint64_t" if not signed else "int64_t"

    ret_ctype = c_type(ret_width, True)
    param_decls = ", ".join(f"{c_type(w, s)} {n}" for n, w, s in params)
    param_names = ", ".join(n for n, _, _ in params)

    # Generate test values based on width
    def test_vals(width):
        if width <= 8: return ["0", "1", "127", "255"]
        if width <= 16: return ["0", "1", "1000", "65535"]
        if width <= 32: return ["0", "1", "42", "1000000", "0xDEADBEEF"]
        return ["0", "1", "42", "0xDEADBEEFCAFE", "0x5555555555555555"]

    lines = []
    lines.append('#include <cstdio>')
    lines.append('#include <cstdint>')
    lines.append('#include <cstdlib>')
    lines.append('')
    lines.append(f'// Original C function (linked from source)')
    lines.append(f'extern "C" {ret_ctype} {module_name}({param_decls});')
    lines.append(f'// Verilator model')
    lines.append(f'extern "C" {ret_ctype} {module_name}_hw({param_decls});')
    lines.append('')
    lines.append('int main() {')
    lines.append(f'    int pass = 0, fail = 0;')
    lines.append(f'    printf("Testing {module_name}: C vs Verilator\\n");')
    lines.append('')

    # Generate test vectors
    vals = test_vals(params[0][1]) if params else ["0"]

    # Generate test vectors: pick fewer values per param to keep test count manageable
    n = len(params)
    per_param = max(2, 5 - n)  # fewer values with more params
    test_vals_per = [test_vals(params[i][1])[:per_param] for i in range(n)]

    # Recursive cartesian product of test values
    def gen_combos(idx, combo):
        if idx == n:
            # Emit one test case
            var_names = [f"p{i}" for i in range(n)]
            decls = "; ".join(
                f"auto {var_names[i]} = ({c_type(params[i][1], params[i][2])}){combo[i]}"
                for i in range(n)
            )
            call_args = ", ".join(var_names)
            lines.append(f'    {{ {decls};')
            lines.append(f'      auto c = {module_name}({call_args});')
            lines.append(f'      auto v = {module_name}_hw({call_args});')
            lines.append(f'      if (c == v) {{ pass++; }} else {{ fail++; printf("  FAIL: C=%lld V=%lld\\n", (long long)c, (long long)v); }}')
            lines.append(f'    }}')
            return
        for val in test_vals_per[idx]:
            gen_combos(idx + 1, combo + [val])

    if n == 0:
        lines.append(f'    {{ auto c = {module_name}(); auto v = {module_name}_hw();')
        lines.append(f'      if (c == v) pass++; else fail++; }}')
    else:
        gen_combos(0, [])

    lines.append('')
    lines.append(f'    printf("{module_name}: %d passed, %d failed\\n", pass, fail);')
    lines.append(f'    return fail ? 1 : 0;')
    lines.append('}')

    return "\n".join(lines)


def run_pipeline(source_file, func_name, keep=False, verbose=False):
    """Full pipeline: C → Verilog → Verilator → test."""

    workdir = tempfile.mkdtemp(prefix=f"c2v_{func_name}_")
    if verbose:
        print(f"Working directory: {workdir}")

    try:
        # Step 1: C → Verilog
        print(f"[1/5] Converting {func_name} to Verilog...")
        result = parse_and_convert(source_file, func_name)
        if not result:
            return 1
        verilog, warnings, params, ret_width = result

        for w in warnings:
            print(f"  WARNING: {w}")

        verilog_file = os.path.join(workdir, f"{func_name}.v")
        with open(verilog_file, 'w') as f:
            f.write(verilog + "\n")

        if verbose:
            print(f"  Verilog:\n{verilog}")

        # Step 2: Generate Verilator wrapper
        print(f"[2/5] Generating Verilator wrapper...")
        wrapper = gen_verilator_wrapper(func_name, params, ret_width)
        wrapper_file = os.path.join(workdir, f"{func_name}_hw.cpp")
        with open(wrapper_file, 'w') as f:
            f.write(wrapper + "\n")

        # Step 3: Generate test main
        print(f"[3/5] Generating test program...")
        test_main = gen_test_main(func_name, params, ret_width)
        test_file = os.path.join(workdir, "test_main.cpp")
        with open(test_file, 'w') as f:
            f.write(test_main + "\n")

        # Step 4: Verilate
        print(f"[4/5] Running Verilator...")
        cmd = [
            "verilator", "--cc", verilog_file,
            "--Mdir", os.path.join(workdir, "obj_dir"),
            "--prefix", f"V{func_name}",
            "-Wno-WIDTH", "-Wno-CMPCONST",
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  Verilator FAILED:\n{r.stderr}")
            return 1

        # Build the Verilator model
        obj_dir = os.path.join(workdir, "obj_dir")
        r = subprocess.run(["make", "-C", obj_dir, "-f", f"V{func_name}.mk"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  Verilator make FAILED:\n{r.stderr}")
            return 1

        # Step 5: Compile and run test
        print(f"[5/5] Compiling and running test...")

        # Find verilator include path
        verilator_root = subprocess.run(
            ["verilator", "--getenv", "VERILATOR_ROOT"],
            capture_output=True, text=True
        ).stdout.strip()
        verilator_inc = os.path.join(verilator_root, "include")

        # Compile: original C as .o, then link with C++ parts
        source_abs = os.path.abspath(source_file)
        test_bin = os.path.join(workdir, "test_run")
        c_obj = os.path.join(workdir, "source.o")

        # Compile C source separately
        r = subprocess.run(
            ["gcc", "-O2", "-c", "-o", c_obj, source_abs],
            capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  C compile FAILED:\n{r.stderr}")
            return 1

        compile_cmd = [
            "g++", "-O2", "-std=c++14",
            "-I", obj_dir,
            "-I", verilator_inc,
            "-o", test_bin,
            test_file,
            wrapper_file,
            c_obj,
            os.path.join(obj_dir, f"V{func_name}__ALL.a"),
            os.path.join(verilator_inc, "verilated.cpp"),
            "-lm",
        ]

        r = subprocess.run(compile_cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  Compile FAILED:\n{r.stderr}")
            return 1

        # Run
        r = subprocess.run([test_bin], capture_output=True, text=True)
        print(r.stdout, end='')
        if r.stderr:
            print(r.stderr, end='')

        if r.returncode == 0:
            print(f"PASS — Verilator model matches C original")
        else:
            print(f"FAIL — mismatches detected")

        return r.returncode

    finally:
        if keep:
            print(f"Work directory kept: {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(
        description="Test C→Verilog conversion via Verilator simulation",
    )
    parser.add_argument("input", help="C source file")
    parser.add_argument("-f", "--function", required=True, help="Function to test")
    parser.add_argument("--keep", action="store_true", help="Keep work directory")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    sys.exit(run_pipeline(args.input, args.function, args.keep, args.verbose))


if __name__ == "__main__":
    main()
