#include <stdint.h>
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)

static inline uint32_t rotr_sw(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32 - n));
}
static inline uint32_t rotr_cfu(uint32_t x, uint32_t n) {
    uint32_t result;
    __asm__ volatile(".insn r 0x0b, 5, 0, %0, %1, %2"
        : "=r"(result) : "r"(x), "r"(n));
    return result;
}

void __attribute__((naked)) _start(void) {
    __asm__ volatile("li sp, 0x80001000");
    __asm__ volatile("j _main");
}
void __attribute__((noinline)) _main(void) {
    uint32_t x = 0xDEADBEEF;
    /* rotr(0xDEADBEEF, 7) = 0xDFBD5B7D */
    IO_RESULT0 = rotr_sw(x, 7);   /* expect 0xDFBD5B7D */
    IO_RESULT1 = rotr_cfu(x, 7);  /* expect 0xDFBD5B7D */
    /* rotr(0xDEADBEEF, 13) = 0x6F56DF7B */
    IO_RESULT2 = rotr_sw(x, 13);  /* expect 0xF77DB56F — let me compute correctly */
    IO_DONE = 1;
    while(1);
}
