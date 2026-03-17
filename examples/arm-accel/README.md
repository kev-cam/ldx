# AArch64 Hardware Accelerator Example

Replaces `sin`/`cos` calls with `UDF` (Undefined Instruction) traps
for hardware acceleration on ARM FPGA SoCs (Zynq, Agilex, etc.).

## Quick Start

```bash
make          # cross-compile + rewrite
make scan     # list rewritable call sites
make diff     # before/after disassembly
```

## What Happens

```
Original:  bl sin@plt  →  PLT → GOT → libm sin()
Patched:   udf #0      →  SIGILL/EL1 trap → handler → FPGA sin
```

## Deploy to ARM Board

```bash
scp accel_demo.hw arm-board:~
# (with kernel module or SIGILL handler installed)
ssh arm-board ./accel_demo.hw
```

## Approaches

| Instruction | Trap Level | Use Case |
|-------------|-----------|----------|
| `UDF #imm16` | EL1 (kernel) | General, works everywhere |
| `HVC #imm16` | EL2 (hypervisor) | Zynq MPSoC with hypervisor |
| `SMC #imm16` | EL3 (secure) | TrustZone-managed FPGA |

Use `-f func:hvc:0x100` or `-f func:smc:0x100` for HVC/SMC variants.
