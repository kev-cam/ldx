/*
 * sim4state_demo.c — 4-state logic simulator hot loop.
 *
 * Models the inner evaluation loop of a digital simulator (like Verilator
 * or Icarus Verilog). Each signal has a 4-state value: 0, 1, X, Z.
 *
 * In software, 4-state operations use lookup tables. With an FPGA-backed
 * custom instruction, each gate evaluation is a single cycle.
 *
 * Workflow:
 *   1. Compile with standard GCC (this file)
 *   2. Profile with ldx to confirm gate_eval is hot
 *   3. Implement gate_eval in FPGA as CUSTOM_0 instruction
 *   4. Rewrite binary: gate_and/gate_or/gate_xor → custom instructions
 *   5. Run on RISC-V + FPGA — same binary, hardware-accelerated gates
 *   6. When proven, tape out the 4-state logic unit as a real extension
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

/* 4-state encoding: 2 bits per signal (val, strength/unknown)
 *   00 = logic 0
 *   01 = logic 1
 *   10 = X (unknown)
 *   11 = Z (high-impedance)
 */
#define S_0 0
#define S_1 1
#define S_X 2
#define S_Z 3

/* Software lookup tables for 4-state AND/OR/XOR.
 * These are the functions we'll replace with custom instructions. */

/* 4-state AND truth table:
 *        0    1    X    Z
 *   0  | 0    0    0    0
 *   1  | 0    1    X    X
 *   X  | 0    X    X    X
 *   Z  | 0    X    X    X  */
static const uint8_t and_table[4][4] = {
    {S_0, S_0, S_0, S_0},
    {S_0, S_1, S_X, S_X},
    {S_0, S_X, S_X, S_X},
    {S_0, S_X, S_X, S_X},
};

static const uint8_t or_table[4][4] = {
    {S_0, S_1, S_X, S_X},
    {S_1, S_1, S_1, S_1},
    {S_X, S_1, S_X, S_X},
    {S_X, S_1, S_X, S_X},
};

static const uint8_t xor_table[4][4] = {
    {S_0, S_1, S_X, S_X},
    {S_1, S_0, S_X, S_X},
    {S_X, S_X, S_X, S_X},
    {S_X, S_X, S_X, S_X},
};

static const uint8_t not_table[4] = {S_1, S_0, S_X, S_X};

/* Gate evaluation functions — rewrite targets.
 * Each takes two 4-state packed words (32 signals per word, 2 bits each)
 * and produces a result word. */

/* __attribute__((noinline)) prevents GCC from inlining these into
 * eval_circuit, so they remain as callable functions with PLT entries
 * when compiled as a shared library — or in this demo, as visible call sites. */

__attribute__((noinline))
uint64_t gate_and(uint64_t a, uint64_t b)
{
    uint64_t result = 0;
    for (int i = 0; i < 32; i++) {
        int sa = (a >> (i * 2)) & 3;
        int sb = (b >> (i * 2)) & 3;
        result |= (uint64_t)and_table[sa][sb] << (i * 2);
    }
    return result;
}

__attribute__((noinline))
uint64_t gate_or(uint64_t a, uint64_t b)
{
    uint64_t result = 0;
    for (int i = 0; i < 32; i++) {
        int sa = (a >> (i * 2)) & 3;
        int sb = (b >> (i * 2)) & 3;
        result |= (uint64_t)or_table[sa][sb] << (i * 2);
    }
    return result;
}

__attribute__((noinline))
uint64_t gate_xor(uint64_t a, uint64_t b)
{
    uint64_t result = 0;
    for (int i = 0; i < 32; i++) {
        int sa = (a >> (i * 2)) & 3;
        int sb = (b >> (i * 2)) & 3;
        result |= (uint64_t)xor_table[sa][sb] << (i * 2);
    }
    return result;
}

__attribute__((noinline))
uint64_t gate_not(uint64_t a)
{
    uint64_t result = 0;
    for (int i = 0; i < 32; i++) {
        int sa = (a >> (i * 2)) & 3;
        result |= (uint64_t)not_table[sa] << (i * 2);
    }
    return result;
}

/* Simulate a simple circuit: (a AND b) XOR (c OR d) */
uint64_t eval_circuit(uint64_t a, uint64_t b, uint64_t c, uint64_t d)
{
    return gate_xor(gate_and(a, b), gate_or(c, d));
}

static const char *state_char(int s) {
    switch (s) { case 0: return "0"; case 1: return "1"; case 2: return "X"; default: return "Z"; }
}

int main(void)
{
    /* Correctness check. */
    printf("4-state gate truth tables:\n\n");
    printf("AND:  0  1  X  Z     OR:  0  1  X  Z     XOR: 0  1  X  Z\n");
    for (int a = 0; a < 4; a++) {
        printf(" %s  ", state_char(a));
        for (int b = 0; b < 4; b++)
            printf(" %s ", state_char(and_table[a][b]));
        printf("      %s  ", state_char(a));
        for (int b = 0; b < 4; b++)
            printf(" %s ", state_char(or_table[a][b]));
        printf("      %s  ", state_char(a));
        for (int b = 0; b < 4; b++)
            printf(" %s ", state_char(xor_table[a][b]));
        printf("\n");
    }

    /* Performance benchmark — simulate many gate evaluations. */
    printf("\nBenchmark: 10M circuit evaluations\n");
    uint64_t a = 0x5555555555555555ULL;  /* all 1s */
    uint64_t b = 0xAAAAAAAAAAAAAAAAULL;  /* all X */
    uint64_t c = 0xFFFFFFFFFFFFFFFFULL;  /* all Z */
    uint64_t d = 0x0000000000000000ULL;  /* all 0 */

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    volatile uint64_t result = 0;
    for (int i = 0; i < 10000000; i++) {
        result = eval_circuit(a ^ i, b ^ i, c ^ i, d ^ i);
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    double ops_per_sec = 10000000.0 / elapsed;
    printf("Time: %.3f s  (%.1f M circuit-evals/s)\n", elapsed, ops_per_sec / 1e6);
    printf("Result: 0x%016lx\n", (unsigned long)result);

    printf("\nWith FPGA acceleration (CUSTOM_0 instructions for gate_and/or/xor),\n");
    printf("each gate_* call becomes a single-cycle instruction operating on\n");
    printf("32 4-state signals in parallel.\n");

    return 0;
}
