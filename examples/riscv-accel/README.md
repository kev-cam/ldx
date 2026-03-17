# RISC-V Hardware Accelerator Example

Demonstrates replacing standard math library calls with custom RISC-V
instructions using the ldx binary rewriter.

## Quick Start

```bash
make          # compile + rewrite
make scan     # list rewritable call sites
make diff     # show before/after disassembly
```

## What Happens

1. `accel_demo.c` uses `sin()`, `cos()`, `sqrt()` from libm
2. Standard GCC compiles these as `jal ra, sin@plt` etc.
3. `riscv_rewrite.py` replaces each 4-byte JAL with a 4-byte CUSTOM_0 instruction
4. The patched binary (`accel_demo.hw`) runs on RISC-V hardware with the custom extension

## Files

| File | Purpose |
|------|---------|
| `accel_demo.c` | Projectile trajectory computation using sin/cos/sqrt |
| `math_accel.json` | Maps sin→funct7=1, cos→funct7=2, sqrt→funct7=3 |
| `Makefile` | Build, rewrite, and diff targets |

## Custom Instruction Encoding

All three use CUSTOM_0 (opcode 0x0B), R-type format:

```
sin:   0x0205050b  →  funct7=1, rd=fa0, rs1=fa0  (fa0 = sin(fa0))
cos:   0x0405050b  →  funct7=2, rd=fa0, rs1=fa0  (fa0 = cos(fa0))
sqrt:  0x0605050b  →  funct7=3, rd=fa0, rs1=fa0  (fa0 = sqrt(fa0))
```

The calling convention alignment is key: GCC puts the first float argument
in `fa0` and expects the return value in `fa0` — the custom instruction
reads and writes the same register.
