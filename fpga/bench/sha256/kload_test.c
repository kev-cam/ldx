#include <stdint.h>
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)
#define IO_RESULT3  (*(volatile uint32_t*)0xF0000010)

static const uint32_t K[4] = {0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5};

void __attribute__((naked)) _start(void) {
    __asm__ volatile("li sp, 0x80001000");
    __asm__ volatile("j _main");
}
void __attribute__((noinline)) _main(void) {
    IO_RESULT0 = K[0];  /* expect 0x428a2f98 */
    IO_RESULT1 = K[1];  /* expect 0x71374491 */
    /* Test stack: write and read back */
    volatile uint32_t x = 0xCAFEBABE;
    IO_RESULT2 = x;     /* expect 0xCAFEBABE */
    IO_RESULT3 = K[2];  /* expect 0xb5c0fbcf */
    IO_DONE = 1;
    while(1);
}
