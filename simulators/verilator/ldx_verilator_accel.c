/* ldx_verilator_accel.c — Verilator runtime primitives for FPGA acceleration.
 *
 * These are the scalar (non-pointer) functions from verilated_funcs.h,
 * rewritten as plain C for c2v conversion. Each function is called
 * millions of times during Verilator simulation.
 *
 * Source: verilator/include/verilated_funcs.h
 * License: LGPL-3.0-only OR Artistic-2.0
 */
#include <stdint.h>

/* Reduction XOR (parity) — used by VL_REDXOR_* */
uint32_t vl_redxor_2(uint32_t r) {
    r = (r ^ (r >> 1));
    return r & 1;
}

uint32_t vl_redxor_4(uint32_t r) {
    r = (r ^ (r >> 1));
    r = (r ^ (r >> 2));
    return r & 1;
}

uint32_t vl_redxor_8(uint32_t r) {
    r = (r ^ (r >> 1));
    r = (r ^ (r >> 2));
    r = (r ^ (r >> 4));
    return r & 1;
}

uint32_t vl_redxor_16(uint32_t r) {
    r = (r ^ (r >> 1));
    r = (r ^ (r >> 2));
    r = (r ^ (r >> 4));
    r = (r ^ (r >> 8));
    return r & 1;
}

uint32_t vl_redxor_32(uint32_t r) {
    r = (r ^ (r >> 1));
    r = (r ^ (r >> 2));
    r = (r ^ (r >> 4));
    r = (r ^ (r >> 8));
    r = (r ^ (r >> 16));
    return r & 1;
}

uint32_t vl_redxor_64(uint64_t r) {
    r = (r ^ (r >> 1));
    r = (r ^ (r >> 2));
    r = (r ^ (r >> 4));
    r = (r ^ (r >> 8));
    r = (r ^ (r >> 16));
    r = (r ^ (r >> 32));
    return (uint32_t)(r & 1);
}

/* Population count — used by VL_COUNTONES_I
 * Original uses octal: 033333333333=0x36DB6DB6, 011111111111=0x24924924, 030707070707=0xC1C71C7 */
uint32_t vl_countones_i(uint32_t lhs) {
    uint32_t r = lhs - ((lhs >> 1) & 0xDB6DB6DB) - ((lhs >> 2) & 0x49249249);
    r = (r + (r >> 3)) & 0xC71C71C7;
    r = (r + (r >> 6));
    r = (r + (r >> 12) + (r >> 24)) & 0x3F;
    return r;
}

/* One-hot check: exactly one bit set */
uint32_t vl_onehot_i(uint32_t lhs) {
    return ((lhs & (lhs - 1)) == 0) & (lhs != 0);
}

uint32_t vl_onehot_q(uint64_t lhs) {
    return ((lhs & (lhs - 1)) == 0) & (lhs != 0);
}

/* One-hot-or-zero: at most one bit set */
uint32_t vl_onehot0_i(uint32_t lhs) {
    return (lhs & (lhs - 1)) == 0;
}

uint32_t vl_onehot0_q(uint64_t lhs) {
    return (lhs & (lhs - 1)) == 0;
}

/* Sign extension — used by VL_EXTENDS_II */
uint32_t vl_extends_ii(uint32_t lbits, uint32_t lhs) {
    return (~((lhs) & (1U << (lbits - 1))) + 1) | lhs;
}

/* Signed greater-than comparison — used by VL_GTS_III */
uint32_t vl_gts_iii(uint32_t lbits, uint32_t lhs, uint32_t rhs) {
    uint32_t sign = 1U << (lbits - 1);
    int32_t slhs = (int32_t)(lhs | -(lhs & sign));
    int32_t srhs = (int32_t)(rhs | -(rhs & sign));
    return slhs > srhs;
}

/* Signed less-than comparison — used by VL_LTS_III */
uint32_t vl_lts_iii(uint32_t lbits, uint32_t lhs, uint32_t rhs) {
    uint32_t sign = 1U << (lbits - 1);
    int32_t slhs = (int32_t)(lhs | -(lhs & sign));
    int32_t srhs = (int32_t)(rhs | -(rhs & sign));
    return slhs < srhs;
}

/* Safe division (returns 0 for divide-by-zero) */
uint32_t vl_div_iii(uint32_t lhs, uint32_t rhs) {
    return (rhs) ? (lhs / rhs) : 0;
}

uint32_t vl_moddiv_iii(uint32_t lhs, uint32_t rhs) {
    return (rhs) ? (lhs % rhs) : 0;
}

/* Count leading zeros (simplified — bounded loop for c2v) */
uint32_t vl_clz_i(uint32_t lhs) {
    uint32_t n = 0;
    if ((lhs & 0xFFFF0000) == 0) { n += 16; lhs <<= 16; }
    if ((lhs & 0xFF000000) == 0) { n += 8; lhs <<= 8; }
    if ((lhs & 0xF0000000) == 0) { n += 4; lhs <<= 4; }
    if ((lhs & 0xC0000000) == 0) { n += 2; lhs <<= 2; }
    if ((lhs & 0x80000000) == 0) { n += 1; }
    if (lhs == 0) n += 1;
    return n;
}

/* Bit reverse 8-bit */
uint32_t vl_bitreverse8(uint32_t v) {
    v = ((v & 0x55) << 1) | ((v & 0xAA) >> 1);
    v = ((v & 0x33) << 2) | ((v & 0xCC) >> 2);
    v = ((v & 0x0F) << 4) | ((v & 0xF0) >> 4);
    return v & 0xFF;
}

/* Byte swap 32-bit */
uint32_t vl_bswap32(uint32_t v) {
    return ((v & 0xFF) << 24) | ((v & 0xFF00) << 8)
         | ((v >> 8) & 0xFF00) | ((v >> 24) & 0xFF);
}
