# vvp hot-path profiles

Profiling Icarus Verilog (vvp 13.0) on x86 (bigsony) running SHA-256 and CRC32
for hash/cycle counts where wall time was multi-second. Rebuilt vvp with `-pg`
into `/tmp/iverilog-pg/vvp/vvp` to get gprof output without root.

## SHA-256 (500 hashes)

```
  18.32%   add_with_carry(vvp_bit4_t, vvp_bit4_t, vvp_bit4_t&)   [28.6 M calls]
   8.91%   vvp_arith_sum::recv_vec4(...)                          [798 K calls]
   4.95%   of_XOR(vthread_s*, vvp_code_s*)                        [318 K calls]
   4.95%   vvp_fun_and::run_run()                                 [162 K calls]
   3.96%   vvp_arith_sub::recv_vec4(...)                          [97 K calls]
   2.97%   vvp_vector4_t::set_bit(unsigned int, vvp_bit4_t)       [15.4 M calls]
   2.97%   vector4_to_value<unsigned long>(...)                   [192 K calls]
   1.98%   of_LOAD_VEC4(...)                                      [1.6 M calls]
   1.53%   operator^(vvp_bit4_t, vvp_bit4_t)                      (inlined; tied with bit XOR)
```

## CRC32 (200k cycles)

```
  13.68%   vvp_vector4_t::set_vec(unsigned int, vvp_vector4_t&)   [56.6 M calls]
   8.96%   of_XOR                                                  [1.8 M calls]
   7.78%   vvp_vector4_t::value(unsigned int) const                [112 M calls]
   5.66%   operator^(vvp_bit4_t, vvp_bit4_t)                       [57.6 M calls]
   4.48%   of_LOAD_VEC4                                            [9.2 M calls]
   4.25%   vvp_vector4_t::set_bit                                  [57.6 M calls]
   3.30%   of_STORE_VEC4                                           [4.8 M calls]
   3.30%   do_CMPS                                                 [2 M calls]
```

## Cross-workload analysis

**Always hot (CFU candidates):**

| function | SHA-256 % | CRC32 % | role |
|---|---|---|---|
| `of_XOR` | 4.95 | 8.96 | 32-bit 4-state XOR |
| `operator^(bit4, bit4)` | 1.53 | 5.66 | per-bit XOR (mostly inlined into of_XOR) |
| `set_bit` / `set_vec` / `value` | ~5 | ~25 | vec4 bit access |
| `of_LOAD_VEC4` / `of_STORE_VEC4` | ~3 | ~8 | memory opcodes |

**Workload-specific:**

| function | role | example workloads |
|---|---|---|
| `add_with_carry`, `vvp_arith_sum::recv_vec4` | adder | SHA-256, ALU-heavy designs |
| `vvp_fun_and::run_run` | AND gate eval | logic-heavy designs |
| `do_CMPS` | comparison | datapath designs with branches |

## CFU plan

The "Verilator-specific RISC-V" (really iverilog-specific) needs a CFU with
these single-cycle instructions:

1. `v4_xor(a1, b1, a2, b2) → (ra, rb)` — already have as `cfu_vl_redxor_32` /
   needs a c2v pass for the 4-state pair version.
2. `v4_and`, `v4_or`, `v4_not` — same shape, generate via c2v on `c2v_ivl.c`.
3. `v4_add(a1, b1, a2, b2, cin) → (sum, cout)` — new c2v target; replaces
   `add_with_carry` for the loop body.
4. `set_bit`, `set_vec`, `value` — memory-bound, hard to accelerate with a
   plain CFU; would need a small register-file alongside the CFU. Probably
   skip in v1.
5. `of_LOAD_VEC4` / `of_STORE_VEC4` — same memory-bound argument.

So v1 CFU = {v4_xor, v4_and, v4_or, v4_not, v4_add}, replacing libvvp.so's
`of_XOR`, `of_AND`, `of_OR`, `of_NOT`, `vvp_arith_sum::recv_vec4`. Expected
combined coverage ≈ 20-30% of vvp's runtime — that's roughly a 1.3-1.5×
speedup on each core, multiplied by the parallelism factor (e.g., 25× on the
5×5 mesh running independent instances).
