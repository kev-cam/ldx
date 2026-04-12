#include <stdint.h>
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)
#define IO_RESULT3  (*(volatile uint32_t*)0xF0000010)

static inline uint32_t rotr(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32 - n));
}
#define SIG0(x) (rotr(x, 7) ^ rotr(x,18) ^ ((x) >> 3))
#define SIG1(x) (rotr(x,17) ^ rotr(x,19) ^ ((x) >> 10))

void __attribute__((naked)) _start(void) {
    __asm__ volatile("li sp, 0x80001000");
    __asm__ volatile("j _main");
}
void __attribute__((noinline)) _main(void) {
    uint32_t w[64];
    uint32_t block[16] = {
        0x61626380, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00000018
    };
    for (int i = 0; i < 16; i++) w[i] = block[i];
    for (int i = 16; i < 64; i++)
        w[i] = SIG1(w[i-2]) + w[i-7] + SIG0(w[i-15]) + w[i-16];

    /* Known values for SHA-256("abc"):
       w[16] = 0x61626380 (same as w[0] because SIG1(w[14])+w[9]+SIG0(w[1])+w[0]
               = SIG1(0)+0+SIG0(0)+0x61626380 = 0x61626380)
       Actually let me compute properly:
       w[16] = SIG1(w[14]) + w[9] + SIG0(w[1]) + w[0]
             = SIG1(0) + 0 + SIG0(0) + 0x61626380
             = 0 + 0 + 0 + 0x61626380 = 0x61626380
    */
    IO_RESULT0 = w[0];   /* expect 0x61626380 */
    IO_RESULT1 = w[15];  /* expect 0x00000018 */
    IO_RESULT2 = w[16];  /* expect 0x61626380 */
    IO_RESULT3 = w[17];  /* expect SIG1(w[15])+w[10]+SIG0(w[2])+w[1] = SIG1(0x18)+0+0+0 */
    IO_DONE = 1;
    while(1);
}
