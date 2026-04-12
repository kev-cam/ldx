#include <stdint.h>
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)

/* These will end up in .rodata at a known address */
static const uint32_t testdata[4] = {0x11223344, 0x55667788, 0xAABBCCDD, 0xEEFF0011};

void __attribute__((naked)) _start(void) {
    __asm__ volatile("li sp, 0x80001000");
    __asm__ volatile("j _main");
}
void __attribute__((noinline)) _main(void) {
    /* Read testdata via pointer (forces a real LW from data section) */
    volatile const uint32_t *p = testdata;
    IO_RESULT0 = p[0];  /* expect 0x11223344 */
    IO_RESULT1 = p[1];  /* expect 0x55667788 */
    IO_DONE = 1;
    while(1);
}
