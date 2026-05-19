// v4cfu_smoke.c — exercise the v4 CFU primitives on one mesh core and
// emit results out the W boundary FIFO. Host loads the same binary into
// every core but only (1,1) is on the data path.

#include "mesh.h"

static inline uint32_t cfu_xor(uint32_t a, uint32_t b) {
    uint32_t r;
    asm volatile (".insn r 0x0B, 0, 0x00, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static inline uint32_t cfu_and(uint32_t a, uint32_t b) {
    uint32_t r;
    asm volatile (".insn r 0x0B, 1, 0x00, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static inline uint32_t cfu_or(uint32_t a, uint32_t b) {
    uint32_t r;
    asm volatile (".insn r 0x0B, 2, 0x00, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static inline uint32_t cfu_not(uint32_t a) {
    uint32_t r;
    asm volatile (".insn r 0x0B, 3, 0x00, %0, %1, x0" : "=r"(r) : "r"(a));
    return r;
}
static inline uint32_t cfu_add(uint32_t a, uint32_t b) {
    uint32_t r;
    asm volatile (".insn r 0x0B, 4, 0x00, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
static inline uint32_t cfu_addcout(uint32_t a, uint32_t b) {
    uint32_t r;
    asm volatile (".insn r 0x0B, 5, 0x00, %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

void main(void) {
    // Only (1,1) participates; others spin.
    if (!(my_x() == 1 && my_y() == 1)) { for (;;) { } }

    const uint32_t A = 0xDEADBEEFu;
    const uint32_t B = 0xCAFEBABEu;
    const uint32_t C = 0xFFFFFFFFu;
    const uint32_t D = 0x80000001u;

    uint32_t out[8];
    out[0] = cfu_xor(A, B);          // expect 0x14170451
    out[1] = cfu_and(A, B);          // expect 0xCAACBAAE
    out[2] = cfu_or (A, B);          // expect 0xDEFDBEFF
    out[3] = cfu_not(A);             // expect 0x21524110
    out[4] = cfu_add(A, B);          // expect 0xA96A79AD
    out[5] = cfu_addcout(A, B);      // expect 1 (overflow into bit 32)
    out[6] = cfu_add(C, D);          // expect 0x80000000
    out[7] = cfu_addcout(C, D);      // expect 1

    // Push the 8 results out the W boundary FIFO for the host to read.
    for (int i = 0; i < 8; i++) {
        while (PUSH_STATUS(DIR_W) & 1u) { }
        PUSH_DATA(DIR_W) = out[i];
    }
    for (;;) { }
}
