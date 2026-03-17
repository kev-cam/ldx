# ARM (AArch64) Call-Site Rewriter

Replace function calls in compiled AArch64 binaries with custom instructions for hardware accelerators, coprocessors, or FPGA-backed extensions.

## ARM vs RISC-V: Key Differences

| | RISC-V | AArch64 |
|---|---|---|
| Call instruction | `jal ra, offset` (4B) | `bl offset` (4B) |
| Custom opcode space | CUSTOM_0–3 (reserved) | No reserved space |
| Extension mechanism | Custom opcodes | UDF trap, HVC/SMC, coprocessor |
| Register convention | a0-a7/fa0-fa7 | x0-x7/d0-d7 (same idea) |
| Instruction size | 4B (or 2B compressed) | Always 4B |

ARM doesn't have a dedicated "custom instruction" opcode space like RISC-V. Instead, there are several approaches to inject custom operations:

### Approach 1: UDF (Undefined Instruction) + Trap Handler

The `UDF` instruction is permanently undefined — it always traps. A custom trap handler catches it and dispatches based on the 16-bit immediate:

```
UDF #imm16    →  trap handler reads imm16, executes custom operation
```

This is the most portable approach. The immediate encodes the operation:

| imm16 bits | Purpose |
|------------|---------|
| 15:12 | Operation class (math=0, logic=1, crypto=2, ...) |
| 11:8 | Operation (sin=0, cos=1, sqrt=2, ...) |
| 7:4 | Source register (0=d0, 1=d1, ...) |
| 3:0 | Dest register (0=d0, 1=d1, ...) |

The trap handler is typically in EL2 (hypervisor) or EL1 (kernel module), and can forward to FPGA via MMIO.

### Approach 2: HVC/SMC (Hypervisor/Secure Monitor Call)

For virtualized environments or TrustZone:

```
HVC #imm16   →  hypervisor handles custom operation
SMC #imm16   →  secure monitor handles custom operation
```

These are designed for exactly this kind of dispatch. The hypervisor can route to FPGA fabric on an SoC.

### Approach 3: Coprocessor Instructions (Legacy/Custom)

Some ARM SoCs (especially FPGA SoCs like Xilinx Zynq) expose FPGA accelerators through custom coprocessor encodings. The exact encoding depends on the SoC.

### Approach 4: SVE/SME Custom Operations

On newer ARM cores with SVE2/SME, the wide vector encoding space can be used for custom SIMD operations. This is SoC-specific.

## Using the Rewriter with ARM

The ldx rewriter works with AArch64 binaries the same way as RISC-V:

### Step 1: Compile with standard GCC

```bash
aarch64-linux-gnu-gcc -O2 -fno-builtin -o myapp myapp.c -lm
```

### Step 2: Scan for call sites

```bash
python3 python/arm_rewrite.py -i myapp --scan

Found 5 call sites:
  0x870  sin
  0x87c  cos
  0x890  sqrt
```

### Step 3: Define the hardware mapping

```json
{
    "sin": {
        "approach": "udf",
        "imm16": "0x0000",
        "comment": "UDF #0 → trap handler calls FPGA sin"
    },
    "cos": {
        "approach": "udf",
        "imm16": "0x0001",
        "comment": "UDF #1 → trap handler calls FPGA cos"
    },
    "sqrt": {
        "approach": "udf",
        "imm16": "0x0002",
        "comment": "UDF #2 → trap handler calls FPGA sqrt"
    }
}
```

Or for HVC-based dispatch:

```json
{
    "sin": {
        "approach": "hvc",
        "imm16": "0x0100",
        "comment": "HVC #256 → hypervisor routes to FPGA trig unit"
    }
}
```

### Step 4: Rewrite

```bash
python3 python/arm_rewrite.py -i myapp -o myapp.hw -m mapping.json
```

### Step 5: Install the trap handler

For UDF-based dispatch, you need a kernel module or hypervisor handler:

```c
/* Kernel module: handle UDF traps for custom operations */
static int handle_undef_insn(struct pt_regs *regs, u32 insn)
{
    if ((insn & 0xFFFF0000) != 0x00000000)  /* not our UDF */
        return 1;  /* pass to default handler */

    u16 op = insn & 0xFFFF;
    switch (op) {
    case 0x0000:  /* sin */
        /* d0 = sin(d0) — read/write FP regs via FPGA MMIO */
        regs->fp_regs.vregs[0] = fpga_sin(regs->fp_regs.vregs[0]);
        break;
    case 0x0001:  /* cos */
        regs->fp_regs.vregs[0] = fpga_cos(regs->fp_regs.vregs[0]);
        break;
    /* ... */
    }
    regs->pc += 4;  /* skip the UDF instruction */
    return 0;
}
```

For the FPGA prototyping use case, the trap overhead (~1µs) is acceptable because the accelerated computation itself would be much larger (e.g., a matrix multiply or FFT). For single-cycle operations like `sin`, the trap overhead dominates — but the point is proving the interface works before committing to silicon.

## AArch64 Instruction Encoding

### BL (Branch with Link) — what we're replacing

```
 31 30 29 28 27 26 25                               0
┌──┬─────────┬──────────────────────────────────────┐
│1 │ 0 0 1 0 │ 1      imm26                         │
└──┴─────────┴──────────────────────────────────────┘
  BL: opcode = 0x94000000 | (imm26 & 0x3FFFFFF)
```

4 bytes. Offset is `imm26 << 2` (signed, ±128MB range).

### UDF (Undefined) — trap-based custom instruction

```
 31                    16 15                          0
┌────────────────────────┬───────────────────────────┐
│ 0000 0000 0000 0000    │         imm16              │
└────────────────────────┴───────────────────────────┘
  UDF: 0x00000000 | (imm16 & 0xFFFF)
```

4 bytes. Always traps to EL1 undefined instruction handler.

### HVC (Hypervisor Call)

```
 31       24 23    21 20         5 4    0
┌──────────┬────────┬─────────────┬──────┐
│ 1101 0100│ 0 0 0  │   imm16     │ 0 10 │
└──────────┴────────┴─────────────┴──────┘
  HVC: 0xD4000002 | ((imm16 & 0xFFFF) << 5)
```

4 bytes. Traps to EL2 hypervisor.

### SMC (Secure Monitor Call)

```
  SMC: 0xD4000003 | ((imm16 & 0xFFFF) << 5)
```

4 bytes. Traps to EL3 secure monitor.

## Encoding Convention for Accelerators

### UDF-based (recommended for FPGA prototyping)

| imm16 | Operation | Registers |
|-------|-----------|-----------|
| 0x0000 | sin | d0 = sin(d0) |
| 0x0001 | cos | d0 = cos(d0) |
| 0x0002 | sqrt | d0 = sqrt(d0) |
| 0x0003 | exp | d0 = exp(d0) |
| 0x0004 | log | d0 = log(d0) |
| 0x0005 | atan2 | d0 = atan2(d0, d1) |
| 0x0100 | gate_and | x0 = gate_and(x0, x1) |
| 0x0101 | gate_or | x0 = gate_or(x0, x1) |
| 0x0102 | gate_xor | x0 = gate_xor(x0, x1) |
| 0x0103 | gate_not | x0 = gate_not(x0) |

The register convention matches the AArch64 calling standard: first arg in x0/d0, second in x1/d1, return in x0/d0. The trap handler reads/writes these registers.

### HVC-based (for SoC with hypervisor)

Same operation encoding in imm16, but routed through the hypervisor. Useful when the FPGA is accessible only from EL2 (e.g., Xilinx Zynq MPSoC with FPGA fabric accessible from the hypervisor).

## Comparison: ARM Approaches

| Approach | Overhead | Portability | FPGA Access |
|----------|----------|-------------|-------------|
| UDF + trap | ~1µs (trap latency) | Any AArch64 | Via MMIO from kernel |
| HVC | ~0.5µs | Needs hypervisor | Via MMIO from EL2 |
| SMC | ~0.5µs | Needs TrustZone | Via secure MMIO |
| Custom coprocessor | ~1 cycle | SoC-specific | Native |

For FPGA prototyping, UDF is the right choice: works on any ARM64 core, easy to set up, and the trap handler is a simple kernel module. When the extension is proven on FPGA, you move to a custom coprocessor encoding for zero-overhead execution.

## ARM FPGA SoC Targets

The rewriter is particularly useful for these platforms:

| Platform | ARM Cores | FPGA Fabric | Access Method |
|----------|-----------|-------------|---------------|
| Xilinx Zynq-7000 | Cortex-A9 (ARMv7) | Artix-7 | AXI MMIO |
| Xilinx Zynq UltraScale+ | Cortex-A53 (AArch64) | UltraScale+ | AXI MMIO, CCI |
| Intel Agilex SoC | Cortex-A53 (AArch64) | Agilex FPGA | AXI/Avalon |
| Microchip PolarFire SoC | SiFive U54 (RISC-V) | PolarFire FPGA | AXI |

On Zynq UltraScale+, the workflow is:
1. Compile app with `aarch64-linux-gnu-gcc`
2. Implement accelerator in FPGA fabric (Vivado)
3. Write kernel module that maps FPGA AXI registers
4. Rewrite binary: `bl sin@plt` → `UDF #0`
5. Trap handler writes d0 to FPGA AXI register, triggers compute, reads result

## Example: 4-State Logic on Zynq

```bash
# Compile simulator for AArch64
aarch64-linux-gnu-gcc -O2 -o sim4state sim4state_demo.c

# Define FPGA-backed operations
cat > zynq_4state.json << 'EOF'
{
    "gate_and": {"approach":"udf", "imm16":"0x0100"},
    "gate_or":  {"approach":"udf", "imm16":"0x0101"},
    "gate_xor": {"approach":"udf", "imm16":"0x0102"},
    "gate_not": {"approach":"udf", "imm16":"0x0103"}
}
EOF

# Rewrite
python3 arm_rewrite.py -i sim4state -o sim4state.hw -m zynq_4state.json

# Deploy to Zynq
scp sim4state.hw zynq-board:~
# (with kernel module loaded for UDF trap → FPGA dispatch)
ssh zynq-board ./sim4state.hw
```

The FPGA implements 4-state logic natively in LUTs — each gate evaluation processes 32 signals in one clock cycle instead of a 32-iteration software loop.

## Integration with ldx Runtime

The rewriter handles static (compile-time-known) acceleration. For dynamic decisions, use ldx runtime features:

```bash
# Profile first to find what's worth accelerating
./ldx -p gate_and,gate_or,sin,cos -- ./myapp

# Static rewrite for known-hot functions
python3 arm_rewrite.py -i myapp -o myapp.hw -m accel.json

# Runtime: still use ldx for dynamic replacement/profiling
LDX_PROFILE=malloc,free LD_PRELOAD=./libldx.so ./myapp.hw
```

## Limitations (ARM-Specific)

- **Trap overhead**: UDF/HVC traps add ~0.5-1µs per call. Only beneficial when the accelerated computation is significantly larger (matrix ops, FFT, crypto, not single `sin` calls). For single-cycle operations, use the RISC-V custom instruction path instead.
- **No user-space custom instructions**: Unlike RISC-V CUSTOM_0, ARM has no user-space custom opcode. All custom operations go through a privilege transition (trap to EL1/EL2). This is a fundamental architectural difference.
- **Kernel module required**: The trap handler must be installed as a kernel module or hypervisor component. This adds deployment complexity compared to RISC-V.
- **BTI (Branch Target Identification)**: On cores with BTI enabled, the UDF instruction at a call return point may cause issues. Test with BTI disabled during prototyping.

## Files

| File | Purpose |
|------|---------|
| `python/arm_rewrite.py` | ARM rewriter tool and Python API |
| `doc/arm-rewriter.md` | This document |
