// main.cpp — Minimal testbench for running Verilator model on bare-metal rv32.
#include "Vcounter.h"

// Minimal bare-metal stubs
extern "C" {
    void _exit(int code) { while(1); }
    void *memset(void *s, int c, unsigned long n) {
        char *p = (char*)s;
        while (n--) *p++ = c;
        return s;
    }
    void *memcpy(void *dst, const void *src, unsigned long n) {
        char *d = (char*)dst;
        const char *s = (const char*)src;
        while (n--) *d++ = *s++;
        return dst;
    }
    int puts(const char *s) { (void)s; return 0; }
    void abort() { while(1); }
    void __cxa_pure_virtual() { while(1); }
}

// Store results so they don't get optimized away
volatile uint8_t result_count;
volatile uint8_t result_overflow;

int main() {
    Vcounter *dut = new Vcounter;

    // Reset
    dut->reset = 1;
    dut->enable = 0;
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    dut->clk = 0;
    dut->eval();

    // Release reset, enable counting
    dut->reset = 0;
    dut->enable = 1;

    // Run 256 clock cycles
    for (int i = 0; i < 256; i++) {
        dut->clk = 1;
        dut->eval();
        dut->clk = 0;
        dut->eval();
    }

    result_count = dut->count;
    result_overflow = dut->overflow;

    // count should be 0 (wrapped around from 255)
    // overflow should have been asserted at count=255

    dut->final();
    delete dut;
    return 0;
}
