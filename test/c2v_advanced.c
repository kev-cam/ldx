/*
 * c2v_advanced.c — Test cases for extended C-to-Verilog conversion.
 * Exercises: shifts, compound assignment, struct returns, bounded loops.
 */
#include <stdint.h>

/* Barrel shift (rotate left) — variable shift amount */
uint64_t barrel_shift(uint64_t val, uint32_t amt)
{
    return (val << amt) | (val >> (64 - amt));
}

/* Compound assignment chain */
uint64_t compound_ops(uint64_t a, uint64_t b, uint64_t c)
{
    uint64_t r = a;
    r |= b;
    r &= c;
    r ^= a;
    return r;
}

/* Multi-way MUX (nested ternary) */
uint32_t priority_encode(uint32_t val)
{
    return (val & 0x80000000) ? 31 :
           (val & 0x40000000) ? 30 :
           (val & 0x20000000) ? 29 :
           (val & 0x10000000) ? 28 :
           (val & 0x0F000000) ? 24 :
           (val & 0x00F00000) ? 20 :
           (val & 0x000F0000) ? 16 :
           (val & 0x0000FF00) ? 8 :
           (val & 0x000000FF) ? 0 : 32;
}

/* Bit manipulation: count leading zeros approximation */
uint32_t has_high_bit(uint32_t val)
{
    return (val >> 16) ? 1 : 0;
}

/* Two-output function — split for c2v (no struct return yet) */
uint64_t swap_halves_lo(uint64_t val)
{
    return (val >> 32);
}

uint64_t swap_halves_hi(uint64_t val)
{
    return (val << 32);
}

uint64_t swap_halves(uint64_t val)
{
    return (val >> 32) | (val << 32);
}

/* Saturating add — clamp at max */
uint32_t sat_add(uint32_t a, uint32_t b)
{
    uint32_t sum = a + b;
    return (sum < a) ? 0xFFFFFFFF : sum;  /* overflow check via wrap */
}

/* Byte reverse (endian swap for 32-bit) */
uint32_t bswap32(uint32_t x)
{
    return ((x >> 24) & 0xFF) |
           ((x >> 8) & 0xFF00) |
           ((x << 8) & 0xFF0000) |
           ((x << 24) & 0xFF000000);
}

/* Parity — XOR all bits (reduce) */
uint32_t parity(uint32_t x)
{
    x ^= x >> 16;
    x ^= x >> 8;
    x ^= x >> 4;
    x ^= x >> 2;
    x ^= x >> 1;
    return x & 1;
}

/* Sign extension from 8 bits to 32 */
int32_t sign_extend_8(int32_t val)
{
    int32_t masked = val & 0xFF;
    return (masked ^ 0x80) - 0x80;
}

/* Popcount approximation — parallel bit sum (SWAR) */
uint32_t popcount_approx(uint32_t x)
{
    x = x - ((x >> 1) & 0x55555555);
    x = (x & 0x33333333) + ((x >> 2) & 0x33333333);
    x = (x + (x >> 4)) & 0x0F0F0F0F;
    return (x * 0x01010101) >> 24;
}
