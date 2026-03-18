/* Test functions for C-to-Verilog conversion. */
#include <stdint.h>

/* Pure combinational: a + b */
int add(int a, int b) {
    return a + b;
}

/* MUX: ternary → multiplexor */
int max(int a, int b) {
    return a > b ? a : b;
}

/* Multi-operation with locals */
int compute(int x, int y, int z) {
    int sum = x + y;
    int prod = x * z;
    return sum > prod ? sum : prod;
}

/* Bitwise: 4-state AND for a single 2-bit pair */
uint8_t and4(uint8_t a, uint8_t b) {
    return (a == 0 || b == 0) ? 0 :
           (a == 1 && b == 1) ? 1 : 2;
}

/* Wide operation */
uint64_t bitwise_blend(uint64_t a, uint64_t b, uint64_t mask) {
    return (a & mask) | (b & ~mask);
}
