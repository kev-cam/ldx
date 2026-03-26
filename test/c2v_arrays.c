/*
 * c2v_arrays.c — Test cases for array and advanced c2v features.
 */
#include <stdint.h>

/* Array element assignment + for-loop reduction */
uint64_t reduce_or4(uint64_t a, uint64_t b, uint64_t c, uint64_t d)
{
    uint64_t vals[4];
    vals[0] = a;
    vals[1] = b;
    vals[2] = c;
    vals[3] = d;
    uint64_t result = 0;
    int i;
    for (i = 0; i < 4; i++) {
        result |= vals[i];
    }
    return result;
}

/* Type cast — truncation */
uint32_t truncate64(uint64_t x)
{
    return (uint32_t)x;
}

/* Type cast — widening */
uint64_t widen32(uint32_t x)
{
    return (uint64_t)x;
}

/* Mixed width operations */
uint32_t mix_widths(uint16_t a, uint8_t b)
{
    return ((uint32_t)a << 8) | (uint32_t)b;
}

/* Nested ternary with casts */
uint32_t clamp8(uint32_t x)
{
    return x > 255 ? 255 : x;
}

/* While loop (simple bounded) — should warn but not crash */
/* uint32_t count_bits_while(uint32_t x)
{
    uint32_t count = 0;
    while (x) { count += x & 1; x >>= 1; }
    return count;
} */

/* Struct with two fields — return via split functions for Verilator test */
typedef struct { uint32_t lo; uint32_t hi; } pair_t;

uint32_t split_lo(uint64_t x)
{
    return (uint32_t)(x & 0xFFFFFFFF);
}

uint32_t split_hi(uint64_t x)
{
    return (uint32_t)(x >> 32);
}

/* Combined: CRC-like operation with shifts, XOR, and conditional */
uint32_t crc_step(uint32_t crc, uint32_t data)
{
    uint32_t xor_val = crc ^ data;
    return (xor_val & 1) ? ((xor_val >> 1) ^ 0xEDB88320) : (xor_val >> 1);
}

/* Fibonacci-like: multi-step with reassignment */
uint32_t fib_step(uint32_t a, uint32_t b, uint32_t n)
{
    uint32_t t;
    t = a + b;
    a = b;
    b = t;
    t = a + b;
    return t;
}
