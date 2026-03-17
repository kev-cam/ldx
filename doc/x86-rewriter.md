# x86_64 Call-Site Rewriter

Replace function calls in x86_64 ELF binaries with custom instruction sequences for hardware acceleration via FPGA over PCIe, or for prototyping new x86 extensions.

## How It Works

x86_64 function calls are `CALL rel32` — a 5-byte instruction (opcode `E8` + 4-byte signed offset). The rewriter replaces this with a 5-byte `UD2 + payload` sequence:

```
Original:     E8 xx xx xx xx         call sin@plt
Replacement:  0F 0B cc oo rr         ud2; .byte class, opcode, reg_hint
              ────── ─────────
              trap   payload (3 bytes)
```

`UD2` (opcode `0F 0B`) triggers an Invalid Opcode (#UD) exception. The trap handler reads the 3-byte payload to determine what operation to perform, executes it (via software emulation, FPGA MMIO, or PCIe DMA), and advances RIP by 5 bytes to continue execution.

## Payload Encoding

| Byte | Name | Purpose |
|------|------|---------|
| 0-1 | `0F 0B` | UD2 — triggers #UD trap |
| 2 | class | Operation class (0=math, 1=logic, 2=crypto, ...) |
| 3 | opcode | Operation within class (0=sin, 1=cos, ...) |
| 4 | reg_hint | Register hint (0x00=xmm0, 0x10=rdi, ...) |

### Operation classes

| Class | Domain | Operations |
|-------|--------|------------|
| 0x00 | Math | sin, cos, sqrt, exp, log, atan2, pow |
| 0x01 | Logic | 4-state AND, OR, XOR, NOT |
| 0x02 | Crypto | AES-round, SHA-round, CRC32 |
| 0x03 | DSP | FFT butterfly, FIR tap, convolution |

### Register hints

| Value | Register | Use case |
|-------|----------|----------|
| 0x00 | xmm0 | Floating-point arg/return |
| 0x01 | xmm1 | Second FP arg |
| 0x10 | rdi | First integer arg |
| 0x11 | rsi | Second integer arg |
| 0x12 | rdx | Third integer arg |
| 0x16 | rax | Integer return |

## Example: Live Acceleration

This example works **right now** on any x86_64 Linux machine:

### Step 1: Compile a test program

```c
// test.c
#include <stdio.h>
#include <math.h>
double compute(double x) { return sin(x) + cos(x); }
int main(void) {
    double r = 0;
    for (int i = 0; i < 1000; i++) r += compute(i * 0.001);
    printf("result = %f\n", r);
    return 0;
}
```

```bash
gcc -O2 -fno-builtin -o test test.c -lm
```

### Step 2: Scan and rewrite

```bash
$ python3 python/x86_rewrite.py -i test --scan
Found 4 call sites:
  0x122e  sin
  0x1242  cos
  0x10d5  sin
  0x10e9  cos

$ python3 python/x86_rewrite.py -i test -o test.hw \
    --func sin:0x00:0x00 --func cos:0x00:0x01

x86_64 call-site rewriter: 4 patches
     Address  Function      Original        Replacement
       0x122e  sin          e85dfeffff      ud2; .byte 0x00,0x00,0x00
       0x1242  cos          e829feffff      ud2; .byte 0x00,0x01,0x00
       ...
```

### Step 3: Run with trap handler

```bash
# Compile the trap handler (LD_PRELOAD library)
gcc -shared -fPIC -O2 -o trap_handler.so test/x86_trap_handler.c -lm

# Run original
$ ./test
result = 1300.977684

# Run patched — UD2 traps handled, same result
$ LD_PRELOAD=./trap_handler.so ./test.hw
x86-trap: handler installed
x86-trap: handled 2000 custom instruction traps
result = 1300.977684
```

The trap handler catches each `ud2`, reads xmm0, computes sin/cos, writes xmm0 back, advances RIP. The result is bit-identical to the original.

### Step 4: Replace software with FPGA

In the trap handler, replace the software `sin()`/`cos()` with FPGA access:

```c
// Software (prototyping):
static void accel_sin(ucontext_t *ctx) {
    set_xmm0(ctx, sin(get_xmm0(ctx)));
}

// FPGA over PCIe (production):
static void accel_sin(ucontext_t *ctx) {
    volatile double *fpga = (volatile double *)fpga_mmio_base;
    fpga[TRIG_INPUT] = get_xmm0(ctx);
    fpga[TRIG_CMD] = CMD_SIN;
    while (fpga[TRIG_STATUS] != DONE) ;
    set_xmm0(ctx, fpga[TRIG_OUTPUT]);
}
```

Same binary, same trap handler interface — just different backend.

## JSON Mapping Format

```json
{
    "sin": {
        "class": "0x00",
        "opcode": "0x00",
        "reg_hint": "xmm0",
        "comment": "sin(xmm0) → xmm0"
    },
    "cos": {
        "class": "0x00",
        "opcode": "0x01",
        "reg_hint": "xmm0",
        "comment": "cos(xmm0) → xmm0"
    },
    "gate_and": {
        "class": "0x01",
        "opcode": "0x00",
        "reg_hint": "rdi",
        "comment": "4-state AND: rdi = gate_and(rdi, rsi)"
    }
}
```

## Trap Handler Architecture

### Userspace (SIGILL)

For development and testing. The `x86_trap_handler.c` LD_PRELOAD library installs a SIGILL handler:

```
Application → UD2 → #UD exception → kernel → SIGILL → handler
  handler reads RIP[2:4] for class/opcode
  handler reads/writes xmm0 (from ucontext fpregs)
  handler advances RIP += 5
  handler returns → application continues
```

Overhead: ~5µs per trap (signal delivery + context switch). Acceptable for prototyping and for operations that take longer than 5µs (matrix multiply, FFT, crypto rounds).

### Kernel module (IDT #UD vector)

For production with lower overhead:

```
Application → UD2 → #UD → kernel handler (directly in IDT)
  handler reads RIP from exception frame
  handler writes to FPGA MMIO
  handler advances RIP += 5
  iret → application continues
```

Overhead: ~1µs. The kernel module registers on the #UD IDT vector and checks for the `0F 0B` + payload signature before dispatching.

### FPGA Targets

| Platform | Interface | Latency |
|----------|-----------|---------|
| Intel HARP / OFS | CCI-P (PCIe) | ~2µs |
| Xilinx Alveo | XDMA (PCIe) | ~3µs |
| Intel PAC | OPAE (MMIO) | ~1µs |
| Local FPGA (GPIO) | Memory-mapped | ~100ns |

## Comparison Across Architectures

| | x86_64 | AArch64 | RISC-V |
|---|---|---|---|
| Call size | 5 bytes | 4 bytes | 4 bytes |
| Replacement | UD2 + 3B payload | UDF #imm16 | CUSTOM_0 R-type |
| Trap mechanism | SIGILL / IDT #UD | SIGILL / EL1 undef | **None (direct execute)** |
| Trap overhead | ~1-5µs | ~0.5-1µs | **0 (pipeline)** |
| Best for | FPGA over PCIe | FPGA SoC (Zynq) | Custom silicon / FPGA |
| Payload bits | 24 (3 bytes) | 16 (imm16) | 17 (funct7+funct3) |

The x86_64 approach has the most payload space (24 bits vs 16-17) but the highest trap overhead. It's ideal for coarse-grained acceleration where the compute saved exceeds the trap cost.

## Files

| File | Purpose |
|------|---------|
| `python/x86_rewrite.py` | Rewriter tool and Python API |
| `test/x86_trap_handler.c` | LD_PRELOAD trap handler (SIGILL) |
| `doc/x86-rewriter.md` | This document |
