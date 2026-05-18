// sim_main.cpp — CRC32 benchmark. Runs N cycles, prints simulated kcycle/s.

#include "VCrc32.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

int main(int argc, char **argv) {
    unsigned long n = (argc >= 2) ? strtoul(argv[1], NULL, 0) : 10000000UL;

    VCrc32 top;
    top.rst = 1; top.en = 0; top.data = 0;
    for (int i = 0; i < 4; i++) { top.clk = 0; top.eval(); top.clk = 1; top.eval(); }
    top.rst = 0; top.en = 1;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    uint32_t lfsr = 0xdeadbeef;
    for (unsigned long i = 0; i < n; i++) {
        // Cheap PRNG for data input
        lfsr ^= lfsr << 13; lfsr ^= lfsr >> 17; lfsr ^= lfsr << 5;
        top.data = (uint8_t)lfsr;
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    double mhz = (double)n / (ns / 1000.0);  // cycles / µs = MHz
    printf("crc=0x%08x  cycles=%lu  wall=%.3f ms  rate=%.3f MHz\n",
           top.crc, n, ns / 1e6, mhz);
    return 0;
}
