#!/usr/bin/env python3
"""
x86_rewrite.py — Binary rewriter for x86_64 custom instruction substitution.

Finds call sites (CALL rel32 instructions) in x86_64 ELF binaries and
replaces them with UD2 + operation code sequences that trap to a custom
handler for hardware acceleration (FPGA over PCIe, etc.).

x86_64 call instruction: E8 xx xx xx xx (5 bytes)
Replacement: 0F 0B xx yy zz (5 bytes)
  0F 0B = UD2 (triggers #UD trap)
  xx    = operation class
  yy    = operation code
  zz    = register hint (which xmm/gpr holds args)

The trap handler at the #UD vector reads RIP to find the ud2, decodes
the 3 trailing bytes, dispatches to FPGA/accelerator, advances RIP by 5.

Usage:
    python3 x86_rewrite.py -i input.elf -o output.elf -m mapping.json
    python3 x86_rewrite.py -i input.elf --scan
    python3 x86_rewrite.py -i input.elf --func sin:0x00:0x00 -o output.elf
"""

import struct
import json
import sys
import os
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Set

# ---- x86_64 instruction encoding ----

EM_X86_64 = 62

def x86_ud2_custom(op_class, op_code, reg_hint=0):
    """Encode a 5-byte UD2 + custom operation sequence.

    Layout: [0F] [0B] [class] [opcode] [reg_hint]
    The #UD handler reads the 3 bytes after UD2 to dispatch.
    """
    return bytes([0x0F, 0x0B, op_class & 0xFF, op_code & 0xFF, reg_hint & 0xFF])


def x86_int3_custom(op_code_hi, op_code_lo, reg_hint=0):
    """Alternative: INT3 + 4-byte payload (5 bytes total).
    INT3 = CC. Trap handler reads next 4 bytes.
    Less intrusive than UD2 (debugger-friendly)."""
    return bytes([0xCC, op_code_hi & 0xFF, op_code_lo & 0xFF,
                  reg_hint & 0xFF, 0x90])  # 0x90 = NOP padding


# Default: 5-byte NOP (for restoring)
X86_NOP5 = bytes([0x0F, 0x1F, 0x44, 0x00, 0x00])


def disasm_replacement(b):
    """Human-readable disassembly of replacement bytes."""
    if len(b) >= 5 and b[0] == 0x0F and b[1] == 0x0B:
        return f"ud2; .byte {b[2]:#04x},{b[3]:#04x},{b[4]:#04x}"
    if len(b) >= 5 and b[0] == 0xCC:
        return f"int3; .byte {b[1]:#04x},{b[2]:#04x},{b[3]:#04x},{b[4]:#04x}"
    return f".bytes {b.hex()}"


# ---- x86_64 ELF parser ----

@dataclass
class ElfSection:
    name: str
    sh_type: int
    sh_addr: int
    sh_offset: int
    sh_size: int
    sh_link: int
    sh_entsize: int

@dataclass
class CallSite:
    address: int
    file_offset: int
    target_func: str
    insn_bytes: bytes  # 5 bytes: E8 + rel32


class X86Elf:
    """Minimal x86_64 ELF parser."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())
        self._parse()

    def _parse(self):
        if self.data[:4] != b'\x7fELF':
            raise ValueError("Not an ELF file")
        if self.data[4] != 2:
            raise ValueError("Not a 64-bit ELF")

        hdr = struct.unpack_from("<HHIQQQIHHHHHH", self.data, 16)
        self.e_machine = hdr[1]
        self.e_shoff = hdr[5]
        self.e_shnum = hdr[11]
        self.e_shstrndx = hdr[12]

        if self.e_machine != EM_X86_64:
            raise ValueError(f"Not an x86_64 binary (e_machine={self.e_machine})")

        self.sections = []
        shdr_fmt = "<IIQQQQIIQQ"
        shdr_size = struct.calcsize(shdr_fmt)
        for i in range(self.e_shnum):
            off = self.e_shoff + i * shdr_size
            s = struct.unpack_from(shdr_fmt, self.data, off)
            sec = ElfSection("", s[1], s[3], s[4], s[5], s[6], s[9])
            sec._name_off = s[0]
            self.sections.append(sec)

        if self.e_shstrndx < len(self.sections):
            strtab = self.sections[self.e_shstrndx]
            for sec in self.sections:
                end = self.data.index(b'\0', strtab.sh_offset + sec._name_off)
                sec.name = self.data[strtab.sh_offset + sec._name_off:end].decode()

    def find_section(self, name):
        for s in self.sections:
            if s.name == name:
                return s
        return None


# ---- Call site discovery ----

def build_func_map(elf: X86Elf, target_funcs: Set[str]) -> Dict[int, str]:
    """Build address → function name map from PLT and symbol table."""
    func_map = {}

    # PLT entries via objdump
    try:
        result = subprocess.run(
            ["objdump", "-d", "-j", ".plt", elf.path],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.splitlines():
            if "@plt>:" in line:
                parts = line.split()
                addr = int(parts[0], 16)
                name = parts[1].lstrip("<").split("@")[0]
                if name in target_funcs:
                    func_map[addr] = name
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Also try .plt.sec (used on newer binaries with CET/IBT)
    try:
        result = subprocess.run(
            ["objdump", "-d", "-j", ".plt.sec", elf.path],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.splitlines():
            if "@plt>:" in line:
                parts = line.split()
                addr = int(parts[0], 16)
                name = parts[1].lstrip("<").split("@")[0]
                if name in target_funcs:
                    func_map[addr] = name
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Local symbols from .symtab
    for sec in elf.sections:
        if sec.sh_type not in (2, 11):
            continue
        strtab_sec = elf.sections[sec.sh_link] if sec.sh_link < len(elf.sections) else None
        if not strtab_sec:
            continue
        sym_fmt = "<IBBHQQ"
        sym_size = 24
        n_syms = sec.sh_size // sym_size
        for i in range(n_syms):
            off = sec.sh_offset + i * sym_size
            if off + sym_size > len(elf.data):
                break
            s = struct.unpack_from(sym_fmt, elf.data, off)
            name_off, info, other, shndx, value, size = s
            if (info & 0xf) != 2 or value == 0:
                continue
            end = elf.data.index(b'\0', strtab_sec.sh_offset + name_off)
            name = elf.data[strtab_sec.sh_offset + name_off:end].decode()
            if name in target_funcs:
                func_map[value] = name

    return func_map


def find_call_sites(elf: X86Elf, target_funcs: Set[str]) -> List[CallSite]:
    """Find all CALL rel32 (E8 xx xx xx xx) call sites to target functions."""
    text = elf.find_section(".text")
    if not text:
        return []

    func_map = build_func_map(elf, target_funcs)
    if not func_map:
        print("Note: no matching functions found", file=sys.stderr)
        return []

    call_sites = []
    data = elf.data
    off = text.sh_offset
    end = text.sh_offset + text.sh_size - 5

    while off <= end:
        if data[off] == 0xE8:  # CALL rel32
            rel32 = struct.unpack_from("<i", data, off + 1)[0]
            pc = text.sh_addr + (off - text.sh_offset)
            target = (pc + 5 + rel32) & 0xFFFFFFFFFFFFFFFF
            func_name = func_map.get(target)
            if func_name:
                call_sites.append(CallSite(
                    address=pc,
                    file_offset=off,
                    target_func=func_name,
                    insn_bytes=bytes(data[off:off + 5]),
                ))
        off += 1  # x86 is byte-addressable, scan every byte

    return call_sites


# ---- Rewriter ----

# Register hint encoding for the 5th byte
REG_HINTS = {
    "xmm0": 0x00, "xmm1": 0x01, "xmm2": 0x02, "xmm3": 0x03,
    "rdi": 0x10, "rsi": 0x11, "rdx": 0x12, "rcx": 0x13,
    "r8": 0x14, "r9": 0x15, "rax": 0x16,
}


class X86Rewriter:
    """Rewrite call sites in an x86_64 ELF binary."""

    def __init__(self, path):
        self.elf = X86Elf(path)
        self.replacements: Dict[str, bytes] = {}

    def add_replacement(self, func_name, replacement_bytes):
        """Register a 5-byte replacement for calls to func_name."""
        assert len(replacement_bytes) == 5, "Replacement must be exactly 5 bytes"
        self.replacements[func_name] = replacement_bytes

    def find_sites(self):
        return find_call_sites(self.elf, set(self.replacements.keys()))

    def rewrite(self, output_path, dry_run=False):
        sites = self.find_sites()
        patches = []

        for site in sites:
            repl = self.replacements[site.target_func]
            patches.append({
                "address": f"0x{site.address:x}",
                "file_offset": f"0x{site.file_offset:x}",
                "function": site.target_func,
                "original": site.insn_bytes.hex(),
                "replacement": repl.hex(),
                "disasm": disasm_replacement(repl),
            })
            if not dry_run:
                self.elf.data[site.file_offset:site.file_offset + 5] = repl

        if not dry_run and output_path:
            with open(output_path, "wb") as f:
                f.write(self.elf.data)
            os.chmod(output_path, 0o755)

        return patches

    def report(self, patches):
        print(f"x86_64 call-site rewriter: {len(patches)} patches")
        print(f"{'Address':>12s}  {'Function':20s}  {'Original':14s}  {'Replacement'}")
        print(f"{'-------':>12s}  {'--------':20s}  {'--------':14s}  {'-----------'}")
        for p in patches:
            print(f"{p['address']:>12s}  {p['function']:20s}  {p['original']:14s}  {p['disasm']}")


# ---- CLI ----

def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Rewrite x86_64 function calls with custom instructions",
        epilog="""
Replacement encoding (5 bytes):  0F 0B <class> <opcode> <reg_hint>
  0F 0B = UD2 (triggers #UD exception)
  class = operation class (00=math, 01=logic, 02=crypto, ...)
  opcode = operation within class (00=sin, 01=cos, 02=sqrt, ...)
  reg_hint = which register holds args (00=xmm0, 10=rdi, ...)

Examples:
  %(prog)s -i app -o app.hw --func sin:0x00:0x00
  %(prog)s -i app -o app.hw -m mapping.json
  %(prog)s -i app --scan
""",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("-i", "--input", required=True, help="Input ELF binary")
    parser.add_argument("-o", "--output", help="Output patched binary")
    parser.add_argument("-m", "--mapping", help="JSON mapping file")
    parser.add_argument("-f", "--func", action="append", default=[],
                        help="FUNC:class:opcode[:reg_hint] (e.g. sin:0x00:0x00)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--scan", action="store_true", help="List all call sites")
    args = parser.parse_args()

    rw = X86Rewriter(args.input)

    if args.scan:
        all_funcs = set()
        for sec in rw.elf.sections:
            if sec.sh_type in (2, 11):
                strtab = rw.elf.sections[sec.sh_link] if sec.sh_link < len(rw.elf.sections) else None
                if not strtab:
                    continue
                for i in range(sec.sh_size // 24):
                    off = sec.sh_offset + i * 24
                    if off + 24 > len(rw.elf.data):
                        break
                    s = struct.unpack_from("<IBBHQQ", rw.elf.data, off)
                    if (s[1] & 0xf) != 2 or s[4] == 0:
                        continue
                    end = rw.elf.data.index(b'\0', strtab.sh_offset + s[0])
                    name = rw.elf.data[strtab.sh_offset + s[0]:end].decode()
                    if name:
                        all_funcs.add(name)
        try:
            for sec_name in [".plt", ".plt.sec"]:
                result = subprocess.run(
                    ["objdump", "-d", "-j", sec_name, rw.elf.path],
                    capture_output=True, text=True, timeout=10)
                for line in result.stdout.splitlines():
                    if "@plt>:" in line:
                        name = line.split()[1].lstrip("<").split("@")[0]
                        all_funcs.add(name)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

        sites = find_call_sites(rw.elf, all_funcs)
        print(f"Found {len(sites)} call sites:")
        for s in sites:
            print(f"  0x{s.address:x}  {s.target_func}")
        return

    if args.mapping:
        with open(args.mapping) as f:
            mapping = json.load(f)
        for func_name, spec in mapping.items():
            op_class = int(spec.get("class", "0"), 0)
            op_code = int(spec.get("opcode", "0"), 0)
            reg_hint = spec.get("reg_hint", 0)
            if isinstance(reg_hint, str):
                reg_hint = REG_HINTS.get(reg_hint, REG_HINTS.get(reg_hint.lower(), 0))
            rw.add_replacement(func_name, x86_ud2_custom(op_class, op_code, reg_hint))

    for spec in args.func:
        parts = spec.split(":")
        func_name = parts[0]
        op_class = int(parts[1], 0) if len(parts) > 1 else 0
        op_code = int(parts[2], 0) if len(parts) > 2 else 0
        reg_hint = int(parts[3], 0) if len(parts) > 3 else 0
        rw.add_replacement(func_name, x86_ud2_custom(op_class, op_code, reg_hint))

    if not rw.replacements:
        print("No replacements specified. Use -m or -f.", file=sys.stderr)
        sys.exit(1)

    output = args.output or (args.input + ".patched" if not args.dry_run else None)
    patches = rw.rewrite(output, dry_run=args.dry_run)
    rw.report(patches)
    if output and not args.dry_run:
        print(f"\nPatched binary written to: {output}")


if __name__ == "__main__":
    main()
