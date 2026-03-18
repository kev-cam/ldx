/*
 * c2v_ivl.c — 4-state vector logic operations from Icarus Verilog (vvp),
 * extracted as standalone C functions for C-to-Verilog conversion.
 *
 * Encoding: each 4-state signal uses 2 bits (abit, bbit) packed into
 * unsigned long words. 64 signals per word on 64-bit systems.
 *
 *   BIT4_0 = ab=00    BIT4_1 = ab=01    BIT4_Z = ab=10    BIT4_X = ab=11
 *
 * These are the inner-loop functions that dominate simulation time.
 * Converting them to Verilog → FPGA gives hardware-speed evaluation.
 */
#include <stdint.h>

/* 4-state AND: implements the Verilog & operator truth table.
 *
 * Truth table (ab encoding):
 *     00 01 11 10
 * 00  00 00 00 00
 * 01  00 01 11 11
 * 11  00 11 11 11
 * 10  00 11 11 11
 */
typedef struct {
    uint64_t abits;
    uint64_t bbits;
} v4word_t;

v4word_t v4_and(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    uint64_t tmp1 = a1 | b1;
    uint64_t tmp2 = a2 | b2;
    v4word_t r;
    r.abits = tmp1 & tmp2;
    r.bbits = (tmp1 & b2) | (tmp2 & b1);
    return r;
}

/* 4-state OR: implements the Verilog | operator.
 *
 * Truth table (ab encoding):
 *     00 01 11 10
 * 00  00 01 11 11
 * 01  01 01 01 01
 * 11  11 01 11 11
 * 10  11 01 11 11
 */
v4word_t v4_or(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    uint64_t tmp = a1 | b1 | a2 | b2;
    v4word_t r;
    r.bbits = ((~a1 | b1) & b2) | ((~a2 | b2) & b1);
    r.abits = tmp;
    return r;
}

/* 4-state XOR: implements the Verilog ^ operator.
 *
 * If either input has X or Z, output is X.
 * Otherwise normal XOR.
 */
v4word_t v4_xor(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    uint64_t has_xz = b1 | b2;
    v4word_t r;
    r.abits = (a1 ^ a2) | has_xz;
    r.bbits = has_xz;
    return r;
}

/* 4-state NOT: implements the Verilog ~ operator.
 * ~0=1, ~1=0, ~X=X, ~Z=X
 */
v4word_t v4_not(uint64_t a, uint64_t b)
{
    uint64_t xz = b | (a & b);
    v4word_t r;
    r.abits = (a ^ 0xFFFFFFFFFFFFFFFF) | xz;
    r.bbits = xz;
    return r;
}

/* Simpler versions that return a/b separately for c2v compatibility
 * (c2v doesn't handle struct returns yet). */

/* AND - return abits */
uint64_t v4_and_a(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    return (a1 | b1) & (a2 | b2);
}

/* AND - return bbits */
uint64_t v4_and_b(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    uint64_t tmp1 = a1 | b1;
    uint64_t tmp2 = a2 | b2;
    return (tmp1 & b2) | (tmp2 & b1);
}

/* OR - return abits */
uint64_t v4_or_a(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    return a1 | b1 | a2 | b2;
}

/* OR - return bbits */
uint64_t v4_or_b(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    return ((~a1 | b1) & b2) | ((~a2 | b2) & b1);
}

/* XOR - return abits */
uint64_t v4_xor_a(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    return (a1 ^ a2) | b1 | b2;
}

/* XOR - return bbits */
uint64_t v4_xor_b(uint64_t a1, uint64_t b1, uint64_t a2, uint64_t b2)
{
    return b1 | b2;
}

/* NOT - return abits */
uint64_t v4_not_a(uint64_t a, uint64_t b)
{
    return (~a) | b;
}

/* NOT - return bbits */
uint64_t v4_not_b(uint64_t a, uint64_t b)
{
    return b;
}
