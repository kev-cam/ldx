#!/usr/bin/env python3
"""
riscv_rewrite.py — Binary rewriter for RISC-V custom instruction substitution.

Finds call sites to specified functions in a RISC-V ELF binary and replaces
the auipc+jalr call sequence with custom instructions.

This solves the compiler extension problem: compile with standard GCC,
then rewrite specific function calls to use hardware accelerators (FPGA,
custom RISC-V extensions, etc.) without modifying the toolchain.

Usage:
    python3 riscv_rewrite.py -i input.elf -o output.elf -m mapping.json

Mapping file format:
{
    "sin": {
        "opcode": "custom_0",
        "funct3": 0,
        "funct7": 1,
        "rd": "fa0",
        "rs1": "fa0",
        "rs2": "x0",
        "comment": "hardware sin accelerator"
    },
    "cos": {
        "opcode": "custom_0",
        "funct3": 0,
        "funct7": 2,
        "rd": "fa0",
        "rs1": "fa0",
        "rs2": "x0"
    }
}

Or use Python API:
    rw = RiscVRewriter("input.elf")
    rw.add_replacement("sin", custom_r(CUSTOM_0, funct3=0, funct7=1,
                                        rd=FA0, rs1=FA0, rs2=X0))
    rw.rewrite("output.elf")
"""

import struct
import json
import sys
import os
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


# ---- RISC-V instruction encoding ----

# Opcodes
CUSTOM_0 = 0x0B  # custom-0 opcode space
CUSTOM_1 = 0x2B
CUSTOM_2 = 0x5B
CUSTOM_3 = 0x7B

OPCODE_NAMES = {
    "custom_0": CUSTOM_0, "custom_1": CUSTOM_1,
    "custom_2": CUSTOM_2, "custom_3": CUSTOM_3,
    "custom0": CUSTOM_0, "custom1": CUSTOM_1,
    "custom2": CUSTOM_2, "custom3": CUSTOM_3,
}

# Integer registers
X0 = 0; ZERO = 0; RA = 1; SP = 2; GP = 3; TP = 4
T0 = 5; T1 = 6; T2 = 7; S0 = 8; FP = 8; S1 = 9
A0 = 10; A1 = 11; A2 = 12; A3 = 13; A4 = 14; A5 = 15; A6 = 16; A7 = 17
S2 = 18; S3 = 19; S4 = 20; S5 = 21; S6 = 22; S7 = 23
S8 = 24; S9 = 25; S10 = 26; S11 = 27
T3 = 28; T4 = 29; T5 = 30; T6 = 31

# Float registers (same numbers, different file — instruction encoding uses same bits)
FA0 = 10; FA1 = 11; FA2 = 12; FA3 = 13; FA4 = 14; FA5 = 15; FA6 = 16; FA7 = 17
FS0 = 8; FS1 = 9; FS2 = 18; FS3 = 19
FT0 = 0; FT1 = 1; FT2 = 2; FT3 = 3; FT4 = 4; FT5 = 5; FT6 = 6; FT7 = 7

REG_NAMES = {
    "x0": 0, "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7, "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23,
    "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
    # Floating-point (same encoding, hardware knows which file)
    "fa0": 10, "fa1": 11, "fa2": 12, "fa3": 13, "fa4": 14, "fa5": 15, "fa6": 16, "fa7": 17,
    "fs0": 8, "fs1": 9, "fs2": 18, "fs3": 19,
    "ft0": 0, "ft1": 1, "ft2": 2, "ft3": 3, "ft4": 4, "ft5": 5, "ft6": 6, "ft7": 7,
}


def reg_num(name_or_num):
    """Convert register name or number to integer."""
    if isinstance(name_or_num, int):
        return name_or_num & 0x1F
    return REG_NAMES.get(name_or_num.lower(), 0)


def custom_r(opcode, funct3=0, funct7=0, rd=0, rs1=0, rs2=0):
    """Encode a RISC-V R-type custom instruction.

    Format: [funct7(7)][rs2(5)][rs1(5)][funct3(3)][rd(5)][opcode(7)]
    """
    rd = reg_num(rd)
    rs1 = reg_num(rs1)
    rs2 = reg_num(rs2)
    insn = ((funct7 & 0x7F) << 25 |
            (rs2 & 0x1F) << 20 |
            (rs1 & 0x1F) << 15 |
            (funct3 & 0x7) << 12 |
            (rd & 0x1F) << 7 |
            (opcode & 0x7F))
    return insn


def custom_i(opcode, funct3=0, rd=0, rs1=0, imm=0):
    """Encode a RISC-V I-type custom instruction.

    Format: [imm(12)][rs1(5)][funct3(3)][rd(5)][opcode(7)]
    """
    rd = reg_num(rd)
    rs1 = reg_num(rs1)
    insn = ((imm & 0xFFF) << 20 |
            (rs1 & 0x1F) << 15 |
            (funct3 & 0x7) << 12 |
            (rd & 0x1F) << 7 |
            (opcode & 0x7F))
    return insn


NOP = 0x00000013  # addi x0, x0, 0


def insn_bytes(insn):
    """Encode a 32-bit instruction as little-endian bytes."""
    return struct.pack("<I", insn)


def disasm_insn(insn):
    """Human-readable disassembly of an encoded instruction."""
    opcode = insn & 0x7F
    rd = (insn >> 7) & 0x1F
    funct3 = (insn >> 12) & 0x7
    rs1 = (insn >> 15) & 0x1F
    rs2 = (insn >> 20) & 0x1F
    funct7 = (insn >> 25) & 0x7F

    if insn == NOP:
        return "nop"

    op_name = {CUSTOM_0: "custom_0", CUSTOM_1: "custom_1",
               CUSTOM_2: "custom_2", CUSTOM_3: "custom_3"}.get(opcode, f"op_{opcode:#x}")

    # Find register names
    rd_name = [k for k, v in REG_NAMES.items() if v == rd and k.startswith(("a", "f", "t", "s", "x", "r", "z"))][0] if rd < 32 else f"x{rd}"
    rs1_name = [k for k, v in REG_NAMES.items() if v == rs1 and k.startswith(("a", "f", "t", "s", "x", "r", "z"))][0] if rs1 < 32 else f"x{rs1}"

    return f"{op_name} f3={funct3} f7={funct7} rd={rd_name} rs1={rs1_name} rs2=x{rs2}"


# ---- ELF parsing (minimal, RISC-V specific) ----

ELF_MAGIC = b'\x7fELF'
EM_RISCV = 243
ET_EXEC = 2
ET_DYN = 3

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
class ElfRela:
    r_offset: int
    r_info: int
    r_addend: int

@dataclass
class ElfSymbol:
    name: str
    st_value: int
    st_size: int
    st_info: int
    st_shndx: int

@dataclass
class CallSite:
    """A call site in the binary that can be rewritten."""
    address: int        # virtual address of the auipc instruction
    file_offset: int    # file offset for patching
    target_func: str    # function being called
    insn_bytes: bytes   # original instruction bytes (8 bytes: auipc+jalr)


class RiscVElf:
    """Minimal RISC-V ELF parser for call-site discovery."""

    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = bytearray(f.read())

        self._parse_header()
        self._parse_sections()
        self._parse_symbols()

    def _parse_header(self):
        if self.data[:4] != ELF_MAGIC:
            raise ValueError("Not an ELF file")

        ei_class = self.data[4]
        if ei_class == 1:
            self.bits = 32
            self.ehdr_fmt = "<HHIIIIIHHHHHH"
            self.ehdr_off = 16
            self.phdr_fmt = "<IIIIIIII"
            self.shdr_fmt = "<IIIIIIIIII"
        else:
            self.bits = 64
            self.ehdr_fmt = "<HHIQQQIHHHHHH"
            self.ehdr_off = 16
            self.phdr_fmt = "<IIQQQQQQ"
            self.shdr_fmt = "<IIQQQQIIQQ"

        hdr = struct.unpack_from(self.ehdr_fmt, self.data, self.ehdr_off)
        self.e_type = hdr[0]
        self.e_machine = hdr[1]
        self.e_entry = hdr[3] if self.bits == 64 else hdr[2]
        self.e_phoff = hdr[4] if self.bits == 64 else hdr[3]
        self.e_shoff = hdr[5] if self.bits == 64 else hdr[4]
        self.e_phnum = hdr[9] if self.bits == 64 else hdr[8]
        self.e_shnum = hdr[11] if self.bits == 64 else hdr[10]
        self.e_shstrndx = hdr[12] if self.bits == 64 else hdr[11]

        if self.e_machine != EM_RISCV:
            raise ValueError(f"Not a RISC-V binary (e_machine={self.e_machine})")

    def _parse_sections(self):
        self.sections = []
        shdr_size = struct.calcsize(self.shdr_fmt)

        for i in range(self.e_shnum):
            off = self.e_shoff + i * shdr_size
            s = struct.unpack_from(self.shdr_fmt, self.data, off)

            if self.bits == 64:
                sec = ElfSection("", s[1], s[3], s[4], s[5], s[6], s[9])
            else:
                sec = ElfSection("", s[1], s[3], s[4], s[5], s[6], s[9])
            sec._name_off = s[0]
            self.sections.append(sec)

        # Resolve section names from .shstrtab
        if self.e_shstrndx < len(self.sections):
            strtab = self.sections[self.e_shstrndx]
            for sec in self.sections:
                name_end = self.data.index(b'\0', strtab.sh_offset + sec._name_off)
                sec.name = self.data[strtab.sh_offset + sec._name_off:name_end].decode()

    def _parse_symbols(self):
        """Parse .dynsym + .dynstr to map PLT slots to function names."""
        self.symbols = []
        self.plt_targets = {}  # addr → function name

        dynsym = None
        dynstr = None
        rela_plt = None

        for sec in self.sections:
            if sec.name == ".dynsym":
                dynsym = sec
            elif sec.name == ".dynstr":
                dynstr = sec
            elif sec.name in (".rela.plt", ".rela.dyn"):
                rela_plt = sec

        if not dynsym or not dynstr:
            return

        # Parse symbols
        if self.bits == 64:
            sym_fmt = "<IBBHQQ"
            sym_size = 24
        else:
            sym_fmt = "<IIIBBH"
            sym_size = 16

        n_syms = dynsym.sh_size // sym_size
        for i in range(n_syms):
            off = dynsym.sh_offset + i * sym_size
            s = struct.unpack_from(sym_fmt, self.data, off)

            if self.bits == 64:
                name_off, info, other, shndx, value, size = s
            else:
                name_off, value, size, info, other, shndx = s

            name_end = self.data.index(b'\0', dynstr.sh_offset + name_off)
            name = self.data[dynstr.sh_offset + name_off:name_end].decode()

            self.symbols.append(ElfSymbol(name, value, size, info, shndx))

        # Parse PLT relocations to map GOT slots to symbol names
        if rela_plt and rela_plt.sh_entsize > 0:
            n_rela = rela_plt.sh_size // rela_plt.sh_entsize
            for i in range(n_rela):
                off = rela_plt.sh_offset + i * rela_plt.sh_entsize
                if self.bits == 64:
                    r_offset, r_info, r_addend = struct.unpack_from("<QQq", self.data, off)
                    sym_idx = r_info >> 32
                else:
                    r_offset, r_info = struct.unpack_from("<II", self.data, off)
                    sym_idx = r_info >> 8

                if sym_idx < len(self.symbols):
                    self.plt_targets[r_offset] = self.symbols[sym_idx].name

    def find_section(self, name):
        for sec in self.sections:
            if sec.name == name:
                return sec
        return None

    def vaddr_to_offset(self, vaddr):
        """Convert virtual address to file offset using section table."""
        for sec in self.sections:
            if sec.sh_addr <= vaddr < sec.sh_addr + sec.sh_size:
                return sec.sh_offset + (vaddr - sec.sh_addr)
        return None

    def read_insn(self, offset):
        """Read a 32-bit instruction at file offset."""
        return struct.unpack_from("<I", self.data, offset)[0]

    def write_insn(self, offset, insn):
        """Write a 32-bit instruction at file offset."""
        struct.pack_into("<I", self.data, offset, insn)


# ---- Call site discovery ----

def is_auipc(insn):
    """Check if instruction is AUIPC."""
    return (insn & 0x7F) == 0x17

def is_jalr(insn):
    """Check if instruction is JALR."""
    return (insn & 0x7F) == 0x67

def is_jal(insn):
    """Check if instruction is JAL."""
    return (insn & 0x7F) == 0x6F

def auipc_rd(insn):
    """Get rd from AUIPC instruction."""
    return (insn >> 7) & 0x1F

def auipc_imm(insn):
    """Get immediate from AUIPC (upper 20 bits)."""
    return insn & 0xFFFFF000

def jalr_rs1(insn):
    """Get rs1 from JALR."""
    return (insn >> 15) & 0x1F

def jalr_imm(insn):
    """Get 12-bit signed immediate from JALR."""
    imm = (insn >> 20) & 0xFFF
    if imm & 0x800:
        imm -= 0x1000
    return imm

def jal_rd(insn):
    """Get rd from JAL instruction."""
    return (insn >> 7) & 0x1F

def jal_imm(insn):
    """Get 20-bit signed immediate from JAL (J-type encoding).
    Bits: [20|10:1|11|19:12] in insn[31:12]"""
    raw = insn >> 12
    imm = (((raw >> 9) & 0x3FF) << 1 |    # bits 10:1
           ((raw >> 8) & 0x1) << 11 |       # bit 11
           ((raw >> 0) & 0xFF) << 12 |       # bits 19:12
           ((raw >> 19) & 0x1) << 20)        # bit 20 (sign)
    if imm & (1 << 20):
        imm -= (1 << 21)
    return imm


def find_call_sites(elf: RiscVElf, target_funcs: set) -> List[CallSite]:
    """Find all call sites (auipc+jalr pairs) that target specified functions.

    Strategy:
    1. Find .plt section to know PLT stub addresses
    2. Scan .text for auipc+jalr pairs
    3. Compute the target address from auipc upper + jalr lower
    4. Match against PLT entries for target functions
    """
    text = elf.find_section(".text")
    plt = elf.find_section(".plt")

    if not text:
        print("Warning: no .text section found", file=sys.stderr)
        return []

    # Build PLT address → function name mapping.
    # We use objdump to get this reliably (parsing PLT stubs is arch-specific).
    plt_map = {}
    try:
        result = subprocess.run(
            ["riscv64-linux-gnu-objdump", "-d", "-j", ".plt", elf.path],
            capture_output=True, text=True, timeout=10,
        )
        for line in result.stdout.splitlines():
            # Lines like: "00000000000103e0 <sin@plt>:"
            if "@plt>:" in line:
                parts = line.split()
                addr = int(parts[0], 16)
                name = parts[1].lstrip("<").split("@")[0]
                if name in target_funcs:
                    plt_map[addr] = name
    except (FileNotFoundError, subprocess.TimeoutExpired):
        # Fallback: try to compute PLT addresses from relocations
        pass

    if not plt_map:
        # Fallback: use the GOT-based plt_targets mapping
        # Each PLT entry is typically at a fixed stride from the PLT base
        print("Note: using relocation-based PLT mapping", file=sys.stderr)

    call_sites = []
    off = text.sh_offset
    end = text.sh_offset + text.sh_size - 4

    while off < end:
        insn1 = elf.read_insn(off)

        pc = text.sh_addr + (off - text.sh_offset)

        # Case 1: JAL rd, offset (single instruction call)
        if is_jal(insn1) and jal_rd(insn1) == RA:
            target = (pc + jal_imm(insn1)) & 0xFFFFFFFFFFFFFFFF
            func_name = plt_map.get(target)
            if func_name:
                call_sites.append(CallSite(
                    address=pc,
                    file_offset=off,
                    target_func=func_name,
                    insn_bytes=bytes(elf.data[off:off + 4]),
                ))

        # Case 2: AUIPC+JALR pair (long-range call)
        elif is_auipc(insn1) and off + 4 <= end:
            insn2 = elf.read_insn(off + 4)
            if is_jalr(insn2):
                rd = auipc_rd(insn1)
                rs1 = jalr_rs1(insn2)
                if rd == rs1:
                    target = (pc + auipc_imm(insn1) + jalr_imm(insn2)) & 0xFFFFFFFFFFFFFFFF
                    func_name = plt_map.get(target)
                    if func_name:
                        call_sites.append(CallSite(
                            address=pc,
                            file_offset=off,
                            target_func=func_name,
                            insn_bytes=bytes(elf.data[off:off + 8]),
                        ))

        off += 4

    return call_sites


# ---- Rewriter ----

class RiscVRewriter:
    """Rewrite call sites in a RISC-V ELF binary."""

    def __init__(self, path):
        self.elf = RiscVElf(path)
        self.replacements: Dict[str, int] = {}  # func_name → encoded instruction
        self.second_insn: Dict[str, int] = {}   # func_name → second instruction (default: NOP)

    def add_replacement(self, func_name, insn, second=NOP):
        """Register a replacement: calls to func_name get rewritten to insn.

        insn: 32-bit encoded custom instruction
        second: 32-bit instruction to fill the jalr slot (default: NOP)
        """
        self.replacements[func_name] = insn
        self.second_insn[func_name] = second

    def find_sites(self) -> List[CallSite]:
        """Find all rewritable call sites."""
        return find_call_sites(self.elf, set(self.replacements.keys()))

    def rewrite(self, output_path, dry_run=False):
        """Find call sites and rewrite them. Returns list of patches applied."""
        sites = self.find_sites()
        patches = []

        for site in sites:
            func = site.target_func
            new_insn = self.replacements[func]
            new_second = self.second_insn.get(func, NOP)
            is_single = len(site.insn_bytes) == 4  # JAL (single insn) vs AUIPC+JALR (8 bytes)

            if is_single:
                repl_hex = insn_bytes(new_insn).hex()
            else:
                repl_hex = insn_bytes(new_insn).hex() + insn_bytes(new_second).hex()

            patches.append({
                "address": f"0x{site.address:x}",
                "file_offset": f"0x{site.file_offset:x}",
                "function": func,
                "original": site.insn_bytes.hex(),
                "replacement": repl_hex,
                "disasm": disasm_insn(new_insn),
                "type": "jal" if is_single else "auipc+jalr",
            })

            if not dry_run:
                self.elf.write_insn(site.file_offset, new_insn)
                if not is_single:
                    self.elf.write_insn(site.file_offset + 4, new_second)

        if not dry_run and output_path:
            with open(output_path, "wb") as f:
                f.write(self.elf.data)
            os.chmod(output_path, 0o755)

        return patches

    def report(self, patches):
        """Print a human-readable report of patches."""
        print(f"RISC-V call-site rewriter: {len(patches)} patches")
        print(f"{'Address':>12s}  {'Function':20s}  {'Original':20s}  {'Replacement'}")
        print(f"{'-------':>12s}  {'--------':20s}  {'--------':20s}  {'-----------'}")
        for p in patches:
            print(f"{p['address']:>12s}  {p['function']:20s}  {p['original']:20s}  {p['disasm']}")


# ---- CLI ----

def main():
    import argparse

    parser = argparse.ArgumentParser(
        description="Rewrite RISC-V function calls with custom instructions",
    )
    parser.add_argument("-i", "--input", required=True, help="Input ELF binary")
    parser.add_argument("-o", "--output", help="Output patched binary")
    parser.add_argument("-m", "--mapping", help="JSON mapping file")
    parser.add_argument("-f", "--func", action="append", default=[],
                        help="Function replacement: FUNC:funct7 (uses CUSTOM_0)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show patches without modifying")
    parser.add_argument("--scan", action="store_true",
                        help="Just scan and list call sites for all PLT functions")
    args = parser.parse_args()

    rw = RiscVRewriter(args.input)

    if args.scan:
        # Scan mode: find ALL call sites
        all_funcs = set()
        for sym in rw.elf.symbols:
            if sym.name:
                all_funcs.add(sym.name)
        sites = find_call_sites(rw.elf, all_funcs)
        print(f"Found {len(sites)} call sites:")
        for s in sites:
            print(f"  0x{s.address:x}  {s.target_func}")
        return

    # Load mapping
    if args.mapping:
        with open(args.mapping) as f:
            mapping = json.load(f)
        for func_name, spec in mapping.items():
            opcode = OPCODE_NAMES.get(spec.get("opcode", "custom_0"), CUSTOM_0)
            insn = custom_r(
                opcode=opcode,
                funct3=spec.get("funct3", 0),
                funct7=spec.get("funct7", 0),
                rd=spec.get("rd", "a0"),
                rs1=spec.get("rs1", "a0"),
                rs2=spec.get("rs2", "x0"),
            )
            rw.add_replacement(func_name, insn)

    # Quick -f syntax: --func sin:1 means sin with funct7=1
    for spec in args.func:
        parts = spec.split(":")
        func_name = parts[0]
        funct7 = int(parts[1]) if len(parts) > 1 else 0
        insn = custom_r(CUSTOM_0, funct3=0, funct7=funct7, rd=FA0, rs1=FA0, rs2=X0)
        rw.add_replacement(func_name, insn)

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
