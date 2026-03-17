# x86_64 Hardware Accelerator Example

Replaces `sin`/`cos` calls with `UD2` trap sequences, handled by a
software trap handler (or FPGA over PCIe in production).

**This example runs live on any x86_64 Linux machine.**

## Quick Start

```bash
make          # compile + rewrite + build trap handler
make run      # run original and patched side-by-side
make scan     # list rewritable call sites
make diff     # before/after disassembly
```

## What Happens

```
Original:  call sin@plt  →  PLT → GOT → libm sin()  (~100+ cycles)
Patched:   ud2 + payload →  SIGILL → handler → sin()  (~5µs trap overhead)
                                      └→ or: FPGA MMIO  (~1µs + compute)
```

Both produce identical results. The trap handler is the prototype;
replace it with FPGA MMIO writes for production acceleration.
