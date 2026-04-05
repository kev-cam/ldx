/* bench_cfu.c — Benchmark: software vs CFU for Verilator primitives.
 *
 * Runs each function N times in a loop, writes iteration count to I/O.
 * The Atom measures wall time to compute throughput.
 *
 * Build WITHOUT CFU (software baseline):
 *   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -fno-inline \
 *     -T fpga.ld -nostdlib -o bench_sw.elf bench_cfu.c ../ldx_verilator_accel.c
 *
 * Build WITH CFU (rewritten):
 *   ... same, then riscv_rewrite.py patches call sites to CUSTOM_0
 */
#include <stdint.h>

#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)
#define IO_RESULT3  (*(volatile uint32_t*)0xF0000010)

/* These are in ldx_verilator_accel.c */
extern uint32_t vl_countones_i(uint32_t lhs);
extern uint32_t vl_redxor_32(uint32_t r);
extern uint32_t vl_onehot_i(uint32_t lhs);
extern uint32_t vl_bswap32(uint32_t v);

#define N_ITERS 1000

void __attribute__((naked)) _start(void) {
    __asm__ volatile ("li sp, 0x80001000");
    __asm__ volatile ("j _main");
}

void __attribute__((noinline)) _main(void) {
    volatile uint32_t sink = 0;
    uint32_t val = 0xDEADBEEF;

    /* Benchmark countones (popcount) */
    for (int i = 0; i < N_ITERS; i++) {
        sink = vl_countones_i(val);
        val ^= sink;  /* prevent optimization */
    }
    IO_RESULT0 = sink;

    /* Benchmark redxor (parity) */
    val = 0xCAFEBABE;
    for (int i = 0; i < N_ITERS; i++) {
        sink = vl_redxor_32(val);
        val ^= (sink << 16);
    }
    IO_RESULT1 = sink;

    /* Benchmark onehot */
    val = 0x00000100;
    for (int i = 0; i < N_ITERS; i++) {
        sink = vl_onehot_i(val);
        val = (val << 1) | sink;
    }
    IO_RESULT2 = sink;

    /* Benchmark bswap */
    val = 0x12345678;
    for (int i = 0; i < N_ITERS; i++) {
        sink = vl_bswap32(val);
        val = sink ^ i;
    }
    IO_RESULT3 = sink;

    IO_DONE = 1;
    while(1);
}
