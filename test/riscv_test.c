/* Simple RISC-V test binary with calls to math functions.
 * Compile: riscv64-linux-gnu-gcc -O2 -o riscv_test riscv_test.c -lm
 * The rewriter will replace sin/cos calls with custom instructions. */
#include <stdio.h>
#include <math.h>

double compute(double x) {
    return sin(x) + cos(x);
}

int main(void) {
    double r = compute(1.0);
    printf("result = %f\n", r);
    return 0;
}
