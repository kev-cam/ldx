/* Same demo as x86 and RISC-V — trajectory computation.
 * Compile: aarch64-linux-gnu-gcc -O2 -fno-builtin -o accel_demo accel_demo.c -lm
 * Rewrite: python3 ../../python/arm_rewrite.py -i accel_demo -o accel_demo.hw -m math_accel.json
 */
#include <stdio.h>
#include <math.h>

double compute(double x) {
    return sin(x) + cos(x);
}

int main(void) {
    volatile double r = 0;
    for (int i = 0; i < 1000; i++)
        r += compute(i * 0.001);
    printf("result = %f\n", r);
    return 0;
}
