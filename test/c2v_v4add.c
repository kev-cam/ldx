/*
 * c2v_v4add.c — 32-bit 4-state adder.
 *
 * vvp_arith_sum::recv_vec4 loops add_with_carry 32 times per vector
 * addition; on SHA-256 that's 18%+9% = 27% of vvp's CPU. One CFU
 * instruction replaces the entire loop.
 *
 * X/Z propagation: for v1, we do conservative smear — if ANY input b-bit
 * is set, ALL output b-bits are set (the whole sum is X). Real iverilog
 * propagates per bit-position; for binary-only workloads (SHA-256,
 * CRC-32, most synthesizable RTL), the X/Z paths never fire and the
 * a-output is just plain integer addition.
 */
#include <stdint.h>

/* Sum a-bits.  b1, b2 are the X/Z masks of the inputs — if any X exists,
 * the X-encoding (a=1, b=1) forces the a-bit to 1 too. */
uint32_t v4_add_a32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2, uint32_t cin)
{
    uint32_t xz = b1 | b2;
    uint32_t sum = a1 + a2 + cin;
    return sum | xz;
}

/* Sum b-bits.  Conservative: if any input has X/Z anywhere, the whole
 * result is X.  Real iverilog smears from the lowest X bit upward; we
 * defer that to a future c2v pass. */
uint32_t v4_add_b32(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2, uint32_t cin)
{
    uint32_t any = b1 | b2;
    uint32_t mask = (any != 0) ? 0xFFFFFFFF : 0;
    (void)a1; (void)a2; (void)cin;
    return mask;
}

/* Carry-out a-bit.  For binary inputs, plain carry of a1 + a2 + cin. */
uint32_t v4_add_cout(uint32_t a1, uint32_t b1, uint32_t a2, uint32_t b2, uint32_t cin)
{
    (void)b1; (void)b2;
    /* Use the property: carry occurs when (a1+a2+cin) overflows 32 bits.
     * Compute via the standard half-adder identity to avoid branching. */
    uint64_t s = (uint64_t)a1 + (uint64_t)a2 + (uint64_t)cin;
    return (uint32_t)(s >> 32);
}
