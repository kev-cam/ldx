#include <stdio.h>
#include <math.h>
double compute(double x) { return sin(x) + cos(x); }
int main(void) {
    volatile double r = 0;
    for (int i = 0; i < 1000; i++) r += compute(i * 0.001);
    printf("result = %f\n", r);
    return 0;
}
