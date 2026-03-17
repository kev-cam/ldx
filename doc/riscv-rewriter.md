# RISC-V Call-Site Rewriter

Replace standard library function calls in compiled RISC-V binaries with custom instructions — no compiler modifications required.

## The Problem

Adding custom instructions to the RISC-V ISA is straightforward in hardware (the CUSTOM_0 through CUSTOM_3 opcode spaces are reserved for exactly this). But getting the compiler to emit those instructions requires modifying GCC or LLVM — adding intrinsics, machine descriptions, and scheduling info. That's a significant toolchain effort for every new extension.

## The Solution

Compile with standard RISC-V GCC. Then use `riscv_rewrite.py` to patch the binary, replacing specific function calls with custom instructions. The tool:

1. Parses the ELF binary to find call sites (JAL and AUIPC+JALR sequences)
2. Matches them against the PLT to identify which function is being called
3. Replaces the call instruction with a custom-encoded instruction

Since RISC-V function calls follow a predictable ABI (arguments in a0-a7/fa0-fa7, return value in a0/fa0), and the custom instruction uses the same register encoding, the surrounding code doesn't change.

## Example: Hardware Math Accelerator

Suppose you have a RISC-V core with a custom floating-point unit that implements `sin` and `cos` in hardware via CUSTOM_0 instructions.

### Step 1: Write normal C code

```c
// accel_demo.c
#include <stdio.h>
#include <math.h>

double compute_trajectory(double angle, double velocity) {
    double vx = velocity * cos(angle);
    double vy = velocity * sin(angle);
    return sqrt(vx * vx + vy * vy);
}

int main(void) {
    for (int i = 0; i < 360; i += 30) {
        double angle = i * M_PI / 180.0;
        double r = compute_trajectory(angle, 100.0);
        printf("angle=%3d  result=%f\n", i, r);
    }
    return 0;
}
```

### Step 2: Compile with standard GCC

```bash
riscv64-linux-gnu-gcc -O2 -fno-builtin -o accel_demo accel_demo.c -lm
```

### Step 3: Scan for call sites

```bash
$ python3 python/riscv_rewrite.py -i accel_demo --scan

Found 5 call sites:
  0x760  cos
  0x774  sin
  0x790  sqrt
  0x7b0  printf
  0x7c8  __libc_start_main
```

### Step 4: Define the hardware mapping

Create `math_accel.json`:

```json
{
    "sin": {
        "opcode": "custom_0",
        "funct3": 0,
        "funct7": 1,
        "rd": "fa0",
        "rs1": "fa0",
        "rs2": "x0",
        "comment": "Hardware sin: fa0 = sin(fa0)"
    },
    "cos": {
        "opcode": "custom_0",
        "funct3": 0,
        "funct7": 2,
        "rd": "fa0",
        "rs1": "fa0",
        "rs2": "x0",
        "comment": "Hardware cos: fa0 = cos(fa0)"
    },
    "sqrt": {
        "opcode": "custom_0",
        "funct3": 0,
        "funct7": 3,
        "rd": "fa0",
        "rs1": "fa0",
        "rs2": "x0",
        "comment": "Hardware sqrt: fa0 = sqrt(fa0)"
    }
}
```

### Step 5: Rewrite the binary

```bash
$ python3 python/riscv_rewrite.py -i accel_demo -o accel_demo.hw -m math_accel.json

RISC-V call-site rewriter: 3 patches
     Address  Function              Original              Replacement
     -------  --------              --------              -----------
       0x760  cos                   eff05fef              custom_0 f3=0 f7=2 rd=fa0 rs1=fa0 rs2=x0
       0x774  sin                   eff01fee              custom_0 f3=0 f7=1 rd=fa0 rs1=fa0 rs2=x0
       0x790  sqrt                  ef1ff0ef              custom_0 f3=0 f7=3 rd=fa0 rs1=fa0 rs2=x0

Patched binary written to: accel_demo.hw
```

### Step 6: Run on hardware

```bash
# The patched binary runs on any RISC-V core that implements these custom instructions.
# On a standard core without the extension, it will trap on the custom opcode
# (which can be caught and emulated in software if needed).
scp accel_demo.hw riscv-board:~
ssh riscv-board ./accel_demo.hw
```

### What changed in the binary

Before (standard library call):
```
760:   ee1ff0ef    jal  ra, 640 <sin@plt>   # call sin via PLT
```

After (custom instruction):
```
760:   0205050b    custom_0  f7=1 rd=fa0 rs1=fa0  # hardware sin
```

The `jal` (4 bytes) is replaced with the custom instruction (4 bytes) — same size, same position. No relocations or surrounding code changes needed.

## Instruction Encoding

The custom instructions use the standard RISC-V R-type format in the CUSTOM_0 opcode space (0x0B):

```
 31      25 24  20 19  15 14 12 11   7 6    0
┌─────────┬──────┬──────┬─────┬──────┬───────┐
│ funct7  │ rs2  │ rs1  │ f3  │  rd  │ opcode│
│  7 bits │5 bits│5 bits│3 bit│5 bits│ 7 bits│
└─────────┴──────┴──────┴─────┴──────┴───────┘
         R-type: CUSTOM_0 = 0000_1011
```

### Opcode spaces

| Opcode | Value | Purpose |
|--------|-------|---------|
| CUSTOM_0 | 0x0B | General extensions |
| CUSTOM_1 | 0x2B | Additional extensions |
| CUSTOM_2 | 0x5B | Coprocessor / accelerator |
| CUSTOM_3 | 0x7B | Vendor-specific |

### Encoding convention for math accelerators

| funct7 | Operation | Signature |
|--------|-----------|-----------|
| 1 | sin | fa0 = sin(fa0) |
| 2 | cos | fa0 = cos(fa0) |
| 3 | sqrt | fa0 = sqrt(fa0) |
| 4 | exp | fa0 = exp(fa0) |
| 5 | log | fa0 = log(fa0) |
| 6 | atan2 | fa0 = atan2(fa0, fa1) |
| 7 | pow | fa0 = pow(fa0, fa1) |

Two-argument functions use rs1=fa0, rs2=fa1 (matching the calling convention).

### I-type encoding

For operations with an immediate parameter, use `custom_i()`:

```python
from riscv_rewrite import custom_i, CUSTOM_0, FA0

# Example: quantize fa0 to N bits (immediate = bit count)
insn = custom_i(CUSTOM_0, funct3=1, rd=FA0, rs1=FA0, imm=8)
```

## Advanced Usage

### Multi-argument functions

Functions with two floating-point arguments (like `atan2(y, x)` or `pow(base, exp)`) naturally map to R-type instructions because the RISC-V calling convention puts the first argument in fa0 and the second in fa1:

```json
{
    "atan2": {
        "opcode": "custom_0",
        "funct3": 0,
        "funct7": 6,
        "rd": "fa0",
        "rs1": "fa0",
        "rs2": "fa1",
        "comment": "fa0 = atan2(fa0, fa1)"
    }
}
```

### Integer operations

For integer functions (like a custom hash or CRC), use the integer registers:

```json
{
    "crc32": {
        "opcode": "custom_1",
        "funct3": 0,
        "funct7": 0,
        "rd": "a0",
        "rs1": "a0",
        "rs2": "a1",
        "comment": "a0 = crc32(a0=data, a1=length)"
    }
}
```

### Selective rewriting

Only rewrite specific call sites by filtering in the mapping. You can also chain with the ldx profiler to identify hot functions worth accelerating:

```bash
# Profile to find hot functions
./ldx -p sin,cos,sqrt,exp -- ./myapp

# Only accelerate the ones that matter
python3 riscv_rewrite.py -i myapp -o myapp.hw --func sin:1 --func cos:2
```

### Software fallback via trap handler

On a core without the custom extension, the CUSTOM_0 opcode triggers an illegal instruction trap. A trap handler can catch this and emulate in software:

```c
// In your trap handler (or M-mode firmware):
void handle_illegal_insn(uint32_t insn, uint64_t *regs) {
    if ((insn & 0x7F) == 0x0B) {  // CUSTOM_0
        int funct7 = (insn >> 25) & 0x7F;
        int rs1 = (insn >> 15) & 0x1F;
        int rd = (insn >> 7) & 0x1F;
        double input = fp_regs[rs1];
        double result;

        switch (funct7) {
            case 1: result = sin(input); break;
            case 2: result = cos(input); break;
            case 3: result = sqrt(input); break;
            default: panic("unknown custom_0 funct7=%d", funct7);
        }
        fp_regs[rd] = result;
        pc += 4;  // skip to next instruction
    }
}
```

This lets the same binary run on both accelerated and standard cores — just slower on the standard core.

## Integration with ldx

The rewriter is part of the ldx programmable linker toolkit. It complements the runtime approaches:

| Approach | When | Overhead | Use case |
|----------|------|----------|----------|
| `dlreplace` (GOT patch) | Runtime | ~3 insns | Swap implementations at runtime |
| `Pipe<>::propagate()` | Runtime | vtable call | Route to FPGA/network/accelerator |
| `riscv_rewrite.py` | Post-compile | **0 insns** | Replace call with custom instruction |

The rewriter gives zero runtime overhead — the custom instruction executes directly in the pipeline. Use it when you know at build time which functions should be accelerated. Use the runtime approaches (Pipe/dlreplace) when the decision is dynamic.

### Combined workflow

```bash
# 1. Compile normally
riscv64-linux-gnu-gcc -O2 -o app app.c -lm

# 2. Rewrite known-accelerated functions
python3 riscv_rewrite.py -i app -o app.hw -m accel.json

# 3. Run with ldx for remaining runtime instrumentation
LDX_PROFILE=malloc,free LD_PRELOAD=./libldx.so ./app.hw
```

## Python API

```python
from riscv_rewrite import RiscVRewriter, custom_r, CUSTOM_0, FA0, X0

# Load binary
rw = RiscVRewriter("app.elf")

# Define replacements
rw.add_replacement("sin", custom_r(CUSTOM_0, funct7=1, rd=FA0, rs1=FA0, rs2=X0))
rw.add_replacement("cos", custom_r(CUSTOM_0, funct7=2, rd=FA0, rs1=FA0, rs2=X0))

# Scan (optional — see what will be patched)
sites = rw.find_sites()
for s in sites:
    print(f"  {s.address:#x}  {s.target_func}")

# Apply patches
patches = rw.rewrite("app.patched")
rw.report(patches)
```

## Limitations

- Currently handles RV64 ELF binaries (RV32 support straightforward to add)
- Compressed instructions (RVC) at call sites are not yet handled — the tool skips them
- The replacement instruction must be 4 bytes (standard RISC-V instruction width)
- Only rewrites direct calls through PLT — indirect calls (`jalr` through function pointers) require runtime interception via ldx GOT patching
- Register mapping assumes the custom instruction uses the same registers as the calling convention (which is the natural design for accelerator instructions)

## Files

| File | Purpose |
|------|---------|
| `python/riscv_rewrite.py` | Rewriter tool and Python API |
| `test/riscv_test.c` | Example C program for testing |
| `test/riscv_mapping.json` | Example hardware mapping (sin/cos) |
| `doc/riscv-rewriter.md` | This document |
