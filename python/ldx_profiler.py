#!/usr/bin/env python3
"""
ldx profiler — profile unmodified binaries via LD_PRELOAD.

Usage:
    python ldx_profiler.py -f sin,cos,strlen ./mybinary [args...]
    python ldx_profiler.py -c profile.json ./mybinary [args...]
    python ldx_profiler.py --list-got ./mybinary

Config file format (JSON):
{
    "profile": ["sin", "cos", "strlen", "libm.so:exp"],
    "replace": {
        "malloc": "mymalloc.so:my_malloc"
    }
}
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def find_libldx():
    """Locate libldx.so."""
    candidates = [
        os.environ.get("LDX_LIB", ""),
        str(Path(__file__).parent.parent / "libldx.so"),
        "/usr/local/lib/libldx.so",
    ]
    for p in candidates:
        if p and os.path.isfile(p):
            return os.path.abspath(p)
    return None


def cmd_profile(args):
    """Run target binary with profiling enabled."""
    libldx = find_libldx()
    if not libldx:
        print("Error: cannot find libldx.so", file=sys.stderr)
        sys.exit(1)

    # Collect symbols to profile.
    symbols = []
    if args.functions:
        symbols.extend(s.strip() for s in args.functions.split(",") if s.strip())

    if args.config:
        with open(args.config) as f:
            cfg = json.load(f)
        symbols.extend(cfg.get("profile", []))

    if not symbols:
        print("Error: no symbols to profile. Use -f or -c.", file=sys.stderr)
        sys.exit(1)

    # Build environment.
    env = os.environ.copy()

    # Add libldx.so to LD_PRELOAD.
    existing = env.get("LD_PRELOAD", "")
    env["LD_PRELOAD"] = f"{libldx}:{existing}" if existing else libldx

    # Set LDX_PROFILE for the constructor to pick up.
    env["LDX_PROFILE"] = ",".join(symbols)

    if args.quiet:
        env["LDX_QUIET"] = "1"

    # Run the target.
    result = subprocess.run(args.command, env=env)
    sys.exit(result.returncode)


def cmd_list_got(args):
    """List all GOT entries in a binary by running it briefly with ldx."""
    libldx = find_libldx()
    if not libldx:
        print("Error: cannot find libldx.so", file=sys.stderr)
        sys.exit(1)

    # We need to load the binary to see its GOT. Use a small helper
    # that loads libldx and walks the GOT.
    helper = r'''
import ctypes, sys, os
lib = ctypes.CDLL(sys.argv[1])
lib.ldx_init.restype = None
lib.ldx_init()

# Also load the target binary as a shared object to see its symbols.
# This only works if target is a shared library. For executables,
# we need LD_PRELOAD.
WALK_CB = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_char_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p, ctypes.c_void_p
)

results = []
@WALK_CB
def cb(sym, libname, slot, val, user):
    s = sym.decode() if sym else ""
    l = libname.decode() if libname else ""
    results.append((s, l))
    return 0

lib.ldx_walk_got.restype = ctypes.c_int
lib.ldx_walk_got(cb, None)

for sym, libname in sorted(results, key=lambda x: (x[1], x[0])):
    print(f"  {sym:40s} {libname}")
'''

    env = os.environ.copy()
    env["LDX_QUIET"] = "1"

    # For executables: use LD_PRELOAD and a tiny C program that walks GOT,
    # or use readelf. Let's use readelf for simplicity.
    print(f"GOT entries from readelf (static view):")
    result = subprocess.run(
        ["readelf", "-r", args.command[0]],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"readelf failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)

    # Parse JUMP_SLOT and GLOB_DAT entries.
    entries = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[2] in ("R_X86_64_JUMP_SLO", "R_X86_64_GLOB_DAT"):
            sym = parts[4].split("@")[0]
            reltype = "PLT" if parts[2] == "R_X86_64_JUMP_SLO" else "GOT"
            entries.append((sym, reltype, parts[0]))

    entries.sort(key=lambda x: x[0])
    print(f"{'Symbol':40s} {'Type':6s} Offset")
    print(f"{'------':40s} {'----':6s} ------")
    for sym, reltype, offset in entries:
        print(f"{sym:40s} {reltype:6s} 0x{offset}")

    print(f"\n{len(entries)} patchable symbols found.")
    print(f"\nTo profile, run:")
    syms = ",".join(e[0] for e in entries[:5])
    print(f"  python {sys.argv[0]} -f {syms} {args.command[0]}")


def main():
    parser = argparse.ArgumentParser(
        description="ldx profiler — instrument unmodified binaries",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s -f sin,cos,strlen ./mybinary
  %(prog)s -c profile.json ./mybinary --flag
  %(prog)s --list-got ./mybinary
  %(prog)s -f '*' ./mybinary          # profile all PLT symbols
""",
    )
    parser.add_argument(
        "-f", "--functions",
        help="Comma-separated list of symbols to profile",
    )
    parser.add_argument(
        "-c", "--config",
        help="JSON config file specifying symbols to profile",
    )
    parser.add_argument(
        "-q", "--quiet",
        action="store_true",
        help="Suppress ldx diagnostic messages",
    )
    parser.add_argument(
        "--list-got",
        action="store_true",
        help="List patchable GOT entries in the target binary",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Command to run (binary + arguments)",
    )

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Strip leading '--' if present.
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]

    if args.list_got:
        cmd_list_got(args)
    else:
        cmd_profile(args)


if __name__ == "__main__":
    main()
