#!/usr/bin/env python3
"""Sanity-check the ARV-on-FPGA SoC over PCIe BAR0.

Reads the magic register, the cpu_reset_reg, and the cpu_done flag.
Lives at /root/arv/test.py on the Atom; install via arv_atom_setup.sh.
"""
import mmap, struct, sys

PCI_DEV = "/sys/bus/pci/devices/0000:01:00.0/resource0"
MAGIC   = 0x4C445832  # "LDX2" little-endian

with open(PCI_DEV, "r+b") as f:
    mm = mmap.mmap(f.fileno(), 8192)
    def rd(off): return struct.unpack("<I", mm[off:off+4])[0]
    m = rd(0x1F80)
    print(f"magic = 0x{m:08X}  reset={rd(0x1F00)}  done={rd(0x1F04)}")
    print("OK" if m == MAGIC else "FAIL")
    sys.exit(0 if m == MAGIC else 1)
