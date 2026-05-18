/*
 * c2v_ivl32.c — 32-bit slice of c2v_ivl.c for our 32-bit CFU bus.
 * Pure-bitwise ops (and/or/xor/not) are independent per bit, so the
 * 64-bit versions just split into two 32-bit halves with identical
 * truth tables. Each c2v output becomes a single CUSTOM_0 instruction.
 *
 * 4-state encoding (per signal): two bits {a, b}.
 *   BIT4_0 = ab=00    BIT4_1 = ab=01    BIT4_Z = ab=10    BIT4_X = ab=11
 *
 * Each input pair (a1,b1) is one 4-state vector word's a-bits and b-bits.
 * We pass them through the CFU as separate 32-bit operands; the C code
 * pairs them via two CUSTOM_0 calls (one for the a-result, one for b).
 */
#include <stdint.h>

/* AND - return a-bits */
uint32_t v4_and_a32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2)
{
    return (a1 | b1) & (a2 | b2);
}

/* AND - return b-bits */
uint32_t v4_and_b32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2)
{
    uint32_t tmp1 = a1 | b1;
    uint32_t tmp2 = a2 | b2;
    return (tmp1 & b2) | (tmp2 & b1);
}

/* OR - return a-bits */
uint32_t v4_or_a32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2)
{
    return a1 | b1 | a2 | b2;
}

/* OR - return b-bits */
uint32_t v4_or_b32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2)
{
    return ((~a1 | b1) & b2) | ((~a2 | b2) & b1);
}

/* XOR - return a-bits */
uint32_t v4_xor_a32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2)
{
    return (a1 ^ a2) | b1 | b2;
}

/* XOR - return b-bits */
uint32_t v4_xor_b32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2)
{
    return b1 | b2;
}

/* NOT - return a-bits */
uint32_t v4_not_a32(uint32_t a, uint32_t b)
{
    return (~a) | b;
}

/* NOT - return b-bits */
uint32_t v4_not_b32(uint32_t a, uint32_t b)
{
    return b;
}
