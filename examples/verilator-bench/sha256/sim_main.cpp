// sim_main.cpp — drive the Verilog Sha256 module for N hashes, measure rate.
// Each hash takes ~67 sim cycles (reset/start setup + 64 round cycles).
#include "VSha256.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

static void load_block_abc(VSha256 &top) {
    // SHA-256("abc"): VL_INW exposes `block` as 16 × 32-bit words; word 0 is
    // the low 32 bits. Verilog reads block[i*32 +: 32] = word i, treated as
    // SHA's standard big-endian message word M_i.
    for (int i = 0; i < 16; i++) top.block[i] = 0;
    top.block[0]  = 0x61626380u;   // 'a','b','c', 0x80 pad
    top.block[15] = 0x00000018u;   // 64-bit length = 24 bits, in M_15 low
}

int main(int argc, char **argv) {
    unsigned long n = (argc >= 2) ? strtoul(argv[1], NULL, 0) : 100000UL;

    VSha256 top;
    top.rst = 1; top.start = 0;
    for (int i = 0; i < 6; i++) { top.clk = 0; top.eval(); top.clk = 1; top.eval(); }
    top.rst = 0;

    load_block_abc(top);

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    unsigned long sim_cycles = 0;
    for (unsigned long h = 0; h < n; h++) {
        top.start = 1;
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
        top.start = 0;
        sim_cycles += 2;
        for (int c = 0; c < 67; c++) {        // 64 rounds + slack
            top.clk = 0; top.eval();
            top.clk = 1; top.eval();
            sim_cycles += 2;
            if (top.done) break;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    double per_hash_us = (ns / (double)n) / 1e3;
    double khps = 1e3 / per_hash_us;
    double sim_mhz = (double)sim_cycles / (ns / 1000.0);

    // VL_OUTW(digest, 255, 0, 8): word i holds bits[(i+1)*32-1 : i*32].
    // The Verilog `digest = {h0, h1, ..., h7}` puts h0 at the high bits,
    // so word 7 = h0, word 6 = h1, ..., word 0 = h7.
    printf("h0..h7 = %08x %08x %08x %08x %08x %08x %08x %08x\n",
           top.digest[7], top.digest[6], top.digest[5], top.digest[4],
           top.digest[3], top.digest[2], top.digest[1], top.digest[0]);
    printf("%lu hashes in %.3f ms  →  %.2f us/hash  →  %.2f kH/s  (%.2f MHz sim)\n",
           n, ns / 1e6, per_hash_us, khps, sim_mhz);
    return 0;
}
