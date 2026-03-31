/* test_loop.c — Minimal loop test for VexRiscv on FPGA.
 * No function calls, just loops and I/O writes.
 */
#include <stdint.h>

#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)
#define IO_RESULT3  (*(volatile uint32_t*)0xF0000010)

void __attribute__((naked)) _start(void) {
    __asm__ volatile ("li sp, 0x80002000");
    __asm__ volatile ("j _main");
}

void __attribute__((noinline)) _main(void) {
    /* Test 1: simple loop sum */
    volatile uint32_t sum = 0;
    for (int i = 0; i < 100; i++) {
        sum += i;
    }
    IO_RESULT0 = sum;  /* expect 4950 */

    /* Test 2: nested computation */
    volatile uint32_t val = 1;
    for (int i = 0; i < 10; i++) {
        val = val * 3;
    }
    IO_RESULT1 = val;  /* expect 59049 (3^10) */

    /* Test 3: bit manipulation loop */
    volatile uint32_t bits = 0;
    for (int i = 0; i < 8; i++) {
        bits |= (1 << i);
    }
    IO_RESULT2 = bits;  /* expect 0xFF = 255 */

    /* Test 4: countdown */
    volatile uint32_t count = 1000;
    while (count > 0) count--;
    IO_RESULT3 = count;  /* expect 0 */

    IO_DONE = 1;
    while (1);
}
