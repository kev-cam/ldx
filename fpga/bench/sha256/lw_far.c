#include <stdint.h>
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)

/* Pad with NOPs to push .rodata to a higher address */
void __attribute__((naked)) _start(void) {
    __asm__ volatile("li sp, 0x80001000");
    __asm__ volatile("j _main");
}

/* 80 NOPs = 320 bytes of padding, so .rodata lands near 0x158 */
__attribute__((section(".text.pad")))
void pad(void) {
    __asm__ volatile(
        ".rept 80\n\tnop\n\t.endr\n"
    );
}

static const uint32_t testdata[4] = {0xDEADBEEF, 0xCAFEBABE, 0x12345678, 0xA5A5A5A5};

void __attribute__((noinline)) _main(void) {
    volatile const uint32_t *p = testdata;
    IO_RESULT0 = p[0];  /* expect 0xDEADBEEF */
    IO_RESULT1 = p[1];  /* expect 0xCAFEBABE */
    IO_DONE = 1;
    while(1);
}
