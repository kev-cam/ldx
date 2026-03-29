# Verilator FPGA Acceleration Analysis

Analysis of Verilator's runtime primitives (`include/verilated_funcs.h`)
for FPGA acceleration via ldx c2v pipeline.

## Summary

| Metric | Count |
|--------|-------|
| Functions extracted | 19 |
| Eligible for FPGA | 19 |
| Successfully converted to Verilog | 16 |
| Verified correct via iverilog | 15 |
| Conversion failures | 3 (sign extension, signed compare — need unary minus support in c2v) |
| Verification failures | 1 (vl_clz_i — if/else chain needs investigation) |

## Verified Accelerator Candidates

These functions are called millions of times during Verilator simulation.
Each is pure combinational logic (no state, no memory, no I/O).

| Function | Purpose | Ops | Est. Gates | Depth | Break-even |
|----------|---------|-----|-----------|-------|------------|
| `vl_redxor_2` | 2-bit parity | 9 | 288 | 4 | >1.5 µs/call |
| `vl_redxor_4` | 4-bit parity | 29 | 928 | 14 | >1.6 µs/call |
| `vl_redxor_8` | 8-bit parity | 73 | 2,336 | 36 | >1.8 µs/call |
| `vl_redxor_16` | 16-bit parity | 165 | 5,280 | 82 | >2.2 µs/call |
| `vl_redxor_32` | 32-bit parity | 353 | 11,296 | 176 | >2.9 µs/call |
| `vl_redxor_64` | 64-bit parity | 733 | 46,912 | 366 | >4.4 µs/call |
| `vl_countones_i` | 32-bit popcount | 431 | 13,792 | 176 | >2.9 µs/call |
| `vl_onehot_i` | 32-bit one-hot check | 5 | 160 | 2 | >1.5 µs/call |
| `vl_onehot_q` | 64-bit one-hot check | 5 | 320 | 2 | >1.5 µs/call |
| `vl_onehot0_i` | 32-bit one-hot-or-zero | 3 | 96 | 1 | >1.5 µs/call |
| `vl_onehot0_q` | 64-bit one-hot-or-zero | 3 | 192 | 1 | >1.5 µs/call |
| `vl_div_iii` | Safe 32-bit divide | 1 | 32 | 1 | >1.5 µs/call |
| `vl_moddiv_iii` | Safe 32-bit modulo | 1 | 32 | 1 | >1.5 µs/call |
| `vl_bitreverse8` | 8-bit reverse | 163 | 5,216 | 72 | >2.1 µs/call |
| `vl_bswap32` | 32-bit byte swap | 19 | 608 | 8 | >1.6 µs/call |

## Not Yet Converted

| Function | Issue | Fix |
|----------|-------|-----|
| `vl_extends_ii` | Unary negation of expression | c2v needs `-(expr)` support |
| `vl_gts_iii` | Unary negation in sign extension | Same |
| `vl_lts_iii` | Unary negation in sign extension | Same |

## Verification Failure

| Function | Issue |
|----------|-------|
| `vl_clz_i` | If/else chain with `<<=` — c2v generates Verilog but test vectors don't match for some inputs |

## Acceleration Strategy

**Per-call overhead**: PCIe Gen1 x1 round-trip is ~1.5 µs (BAR write + BAR read).
Individual function calls are too fast on CPU to benefit from FPGA offload.

**Where FPGA wins**:

1. **Batched evaluation**: When the same function is called on many values
   (e.g., evaluating a wide bus word-by-word), batch the inputs into FPGA
   memory and trigger parallel evaluation. A single PCIe write can deliver
   multiple arguments.

2. **Pipelined dataflow**: Chain multiple operations in the FPGA fabric
   (e.g., countones → redxor → onehot) without PCIe round-trips between
   stages. The interconnect latency is zero inside the FPGA.

3. **Wide operations**: Functions like `VL_REDXOR_W` and `VL_COUNTONES_W`
   operate on wide vectors word-by-word on CPU. An FPGA can process the
   entire width in one cycle with a wide datapath.

4. **Generated model acceleration**: Instead of accelerating individual
   runtime primitives, use c2v on the *generated* Verilator model itself.
   The `V<module>___024root__comb` evaluation function is often a large
   combinational block that maps naturally to FPGA fabric.

## Files

- `ldx_verilator_accel.c` — C source with extracted functions
- `ldx_accel_manifest.json` — Machine-readable scan results
- Analysis performed with: `ldx/python/ldx_accel_scan.py`

## Method

```bash
# Extract scalar functions from verilated_funcs.h into plain C
# Run ldx accelerator scanner:
cd /usr/local/src/ldx
python3 python/ldx_accel_scan.py estimate /usr/local/src/verilator/ldx_verilator_accel.c -v
python3 python/ldx_accel_scan.py manifest /usr/local/src/verilator/ldx_verilator_accel.c -o ldx_accel_manifest.json
```
