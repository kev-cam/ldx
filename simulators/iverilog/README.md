# iverilog (vvp) gate library

c2v-generated combinational Verilog for the inner-loop operations that
dominate Icarus Verilog's vvp interpreter. Each gate replaces a hot
`libvvp.so` function — when a softcore has these as CUSTOM_0 instructions,
the matching opcode handler in vvp collapses from a ~30-cycle C++ dispatch
to a single CFU call.

## Files

| .v                  | replaces in libvvp.so                              | source                |
| ------------------- | --------------------------------------------------- | --------------------- |
| `v4_and_a32.v`      | `vvp_fun_and::run_run`, `operator&(bit4,bit4)` (a) | `test/c2v_ivl32.c`    |
| `v4_and_b32.v`      |    "                                  (b mask)     | `test/c2v_ivl32.c`    |
| `v4_or_a32.v`       | `of_OR`, `operator\|`                              (a) | `test/c2v_ivl32.c` |
| `v4_or_b32.v`       |    "                                  (b mask)     | `test/c2v_ivl32.c`    |
| `v4_xor_a32.v`      | `of_XOR`, `operator^`                  (a)         | `test/c2v_ivl32.c`    |
| `v4_xor_b32.v`      |    "                                  (b mask)     | `test/c2v_ivl32.c`    |
| `v4_not_a32.v`      | `of_NOT`                              (a)         | `test/c2v_ivl32.c`    |
| `v4_not_b32.v`      |    "                                  (b mask)     | `test/c2v_ivl32.c`    |
| `v4_add_a32.v`      | `vvp_arith_sum::recv_vec4`            (sum a)     | `test/c2v_v4add.c`    |
| `v4_add_b32.v`      |    "                                  (sum b)     | `test/c2v_v4add.c`    |
| `v4_add_cout.v`     |    "                                  (cout)      | `test/c2v_v4add.c`    |

## 4-state encoding

Each signal is two bits, `{a, b}`:

| a | b | meaning |
|---|---|---------|
| 0 | 0 | 0       |
| 1 | 0 | 1       |
| 0 | 1 | Z       |
| 1 | 1 | X       |

For workloads without X/Z (most synthesizable RTL, including SHA-256 and
CRC32), the b inputs are 0 and the gates degenerate to plain bitwise /
arithmetic ops on the a bits. The CFU value in that case is not the gate
logic itself but eliminating the per-bit C++ dispatch loop in vvp.

## Coverage (per gprof on x86 vvp)

Replacing the 5 ops below as single-cycle CUSTOM_0 instructions covers
roughly 25-30% of vvp's runtime on the SHA-256 and CRC32 benchmarks:

  of_XOR                  4.95 / 8.96 %    (SHA / CRC)
  vvp_fun_and::run_run    4.95 / —
  of_OR / of_NOT          (smaller, but free given they're already in c2v)
  vvp_arith_sum::recv_vec4   8.91 / —
  add_with_carry         18.32 / —        (folded into vvp_arith_sum CFU)

## Add propagation caveat

`v4_add_b32` does conservative X/Z smear: any X in any input → whole sum
is X. Real iverilog smears from the lowest X bit upward through the carry
chain. For binary-only workloads this difference doesn't matter; revisit
when we run a workload that needs accurate X-on-add semantics.
