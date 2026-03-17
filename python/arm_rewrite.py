#!/usr/bin/env python3
"""
arm_rewrite.py — Binary rewriter for AArch64 custom instruction substitution.

Finds call sites (BL instructions) in AArch64 ELF binaries and replaces
them with UDF (trap), HVC, or SMC instructions for hardware acceleration.

Usage:
    python3 arm_rewrite.py -i input.elf -o output.elf -m mapping.json
    python3 arm_rewrite.py -i input.elf --scan
    python3 arm_rewrite.py -i input.elf --func sin:udf:0x0000 -o output.elf
"""

import struct
import json
import sys
import os
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Set

# Reuse ELF parsing infrastructure from riscv_rewrite
sys.path.insert(0, os.path.dirname(__file__))

# ---- AArch64 instruction encoding ----

EM_AARCH64 = 183

def arm_udf(imm16):
    """Encode AArch64 UDF (permanently undefined) instruction.
    Encoding: 0x00000000 | (imm16 & 0xFFFF)"""
    return imm16 & 0xFFFF

def arm_hvc(imm16):
    """Encode AArch64 HVC (hypervisor call) instruction.
    Encoding: 0xD4000002 | ((imm16 & 0xFFFF) << 5)"""
    return 0xD4000002 | ((imm16 & 0xFFFF) << 5)

def arm_smc(imm16):
    """Encode AArch64 SMC (secure monitor call) instruction.
    Encoding: 0xD4000003 | ((imm16 & 0xFFFF) << 5)"""
    return 0xD4000003 | ((imm16 & 0xFFFF) << 5)

def arm_nop():
    """AArch64 NOP."""
    return 0xD503201F

APPROACH_ENCODERS = {
    "udf": arm_udf,
    "hvc": arm_hvc,
    "smc": arm_smc,
}

def insn_bytes(insn):
    """Encode a 32-bit instruction as little-endian bytes."""
    return struct.pack("<I", insn)

def disasm_insn(insn):
    """Human-readable disassembly of a replacement instruction."""
    if insn == arm_nop():
        return "nop"
    if (insn & 0xFFFF0000) == 0:
        return f"udf #{insn & 0xFFFF:#06x}"
    if (insn & 0xFFE0001F) == 0xD4000002:
        imm = (insn >> 5) & 0xFFFF
        return f"hvc #{imm:#06x}"
    if (insn & 0xFFE0001F) == 0xD4000003:
        imm = (insn >> 5) & 0xFFFF
        return f"smc #{imm:#06x}"
    return f".word {insn:#010x}"


# ---- AArch64 ELF parser ----

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
    insn_bytes: bytes


class AArch64Elf:
    """Minimal AArch64 ELF parser."""

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

        if self.e_machine != EM_AARCH64:
            raise ValueError(f"Not an AArch64 binary (e_machine={self.e_machine})")

        # Parse sections
        self.sections = []
        shdr_fmt = "<IIQQQQIIQQ"
        shdr_size = struct.calcsize(shdr_fmt)
        for i in range(self.e_shnum):
            off = self.e_shoff + i * shdr_size
            s = struct.unpack_from(shdr_fmt, self.data, off)
            sec = ElfSection("", s[1], s[3], s[4], s[5], s[6], s[9])
            sec._name_off = s[0]
            self.sections.append(sec)

        # Resolve names
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

    def read_insn(self, offset):
        return struct.unpack_from("<I", self.data, offset)[0]

    def write_insn(self, offset, insn):
        struct.pack_into("<I", self.data, offset, insn)


# ---- AArch64 instruction detection ----

def is_bl(insn):
    """Check if instruction is BL (Branch with Link)."""
    return (insn & 0xFC000000) == 0x94000000

def bl_offset(insn):
    """Get signed byte offset from BL instruction."""
    imm26 = insn & 0x3FFFFFF
    if imm26 & (1 << 25):
        imm26 -= (1 << 26)
    return imm26 << 2


# ---- Call site discovery ----

def build_func_map(elf: AArch64Elf, target_funcs: Set[str]) -> Dict[int, str]:
    """Build address → function name map from PLT and symbol table."""
    func_map = {}

    # PLT entries via objdump
    try:
        result = subprocess.run(
            ["aarch64-linux-gnu-objdump", "-d", "-j", ".plt", elf.path],
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
        if sec.sh_type not in (2, 11):  # SHT_SYMTAB, SHT_DYNSYM
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


def find_call_sites(elf: AArch64Elf, target_funcs: Set[str]) -> List[CallSite]:
    """Find all BL call sites to target functions."""
    text = elf.find_section(".text")
    if not text:
        return []

    func_map = build_func_map(elf, target_funcs)
    if not func_map:
        print("Note: no matching functions found", file=sys.stderr)
        return []

    call_sites = []
    off = text.sh_offset
    end = text.sh_offset + text.sh_size - 4

    while off <= end:
        insn = elf.read_insn(off)
        if is_bl(insn):
            pc = text.sh_addr + (off - text.sh_offset)
            target = (pc + bl_offset(insn)) & 0xFFFFFFFFFFFFFFFF
            func_name = func_map.get(target)
            if func_name:
                call_sites.append(CallSite(
                    address=pc,
                    file_offset=off,
                    target_func=func_name,
                    insn_bytes=bytes(elf.data[off:off + 4]),
                ))
        off += 4  # AArch64 instructions are always 4 bytes

    return call_sites


# ---- Rewriter ----

class AArch64Rewriter:
    """Rewrite call sites in an AArch64 ELF binary."""

    def __init__(self, path):
        self.elf = AArch64Elf(path)
        self.replacements: Dict[str, int] = {}

    def add_replacement(self, func_name, insn):
        self.replacements[func_name] = insn

    def find_sites(self):
        return find_call_sites(self.elf, set(self.replacements.keys()))

    def rewrite(self, output_path, dry_run=False):
        sites = self.find_sites()
        patches = []

        for site in sites:
            new_insn = self.replacements[site.target_func]
            patches.append({
                "address": f"0x{site.address:x}",
                "file_offset": f"0x{site.file_offset:x}",
                "function": site.target_func,
                "original": site.insn_bytes.hex(),
                "replacement": insn_bytes(new_insn).hex(),
                "disasm": disasm_insn(new_insn),
            })
            if not dry_run:
                self.elf.write_insn(site.file_offset, new_insn)

        if not dry_run and output_path:
            with open(output_path, "wb") as f:
                f.write(self.elf.data)
            os.chmod(output_path, 0o755)

        return patches

    def report(self, patches):
        print(f"AArch64 call-site rewriter: {len(patches)} patches")
        print(f"{'Address':>12s}  {'Function':20s}  {'Original':12s}  {'Replacement'}")
        print(f"{'-------':>12s}  {'--------':20s}  {'--------':12s}  {'-----------'}")
        for p in patches:
            print(f"{p['address']:>12s}  {p['function']:20s}  {p['original']:12s}  {p['disasm']}")


# ---- CLI ----

def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Rewrite AArch64 function calls with custom instructions",
    )
    parser.add_argument("-i", "--input", required=True, help="Input ELF binary")
    parser.add_argument("-o", "--output", help="Output patched binary")
    parser.add_argument("-m", "--mapping", help="JSON mapping file")
    parser.add_argument("-f", "--func", action="append", default=[],
                        help="Replacement: FUNC:approach:imm16 (e.g. sin:udf:0x0000)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--scan", action="store_true",
                        help="List all call sites")
    args = parser.parse_args()

    rw = AArch64Rewriter(args.input)

    if args.scan:
        all_funcs = set()
        for sec in rw.elf.sections:
            if sec.sh_type in (2, 11):
                strtab = rw.elf.sections[sec.sh_link] if sec.sh_link < len(rw.elf.sections) else None
                if not strtab:
                    continue
                sym_size = 24
                for i in range(sec.sh_size // sym_size):
                    off = sec.sh_offset + i * sym_size
                    if off + sym_size > len(rw.elf.data):
                        break
                    s = struct.unpack_from("<IBBHQQ", rw.elf.data, off)
                    if (s[1] & 0xf) != 2 or s[4] == 0:
                        continue
                    end = rw.elf.data.index(b'\0', strtab.sh_offset + s[0])
                    name = rw.elf.data[strtab.sh_offset + s[0]:end].decode()
                    if name:
                        all_funcs.add(name)
        # Also get PLT names
        try:
            result = subprocess.run(
                ["aarch64-linux-gnu-objdump", "-d", "-j", ".plt", rw.elf.path],
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
            approach = spec.get("approach", "udf")
            imm_str = spec.get("imm16", "0")
            imm16 = int(imm_str, 0) if isinstance(imm_str, str) else int(imm_str)
            encoder = APPROACH_ENCODERS.get(approach, arm_udf)
            rw.add_replacement(func_name, encoder(imm16))

    for spec in args.func:
        parts = spec.split(":")
        func_name = parts[0]
        approach = parts[1] if len(parts) > 1 else "udf"
        imm16 = int(parts[2], 0) if len(parts) > 2 else 0
        encoder = APPROACH_ENCODERS.get(approach, arm_udf)
        rw.add_replacement(func_name, encoder(imm16))

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
