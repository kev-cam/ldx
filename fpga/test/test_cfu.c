/* test_cfu.c — Test program for VexRiscv + ldx CFU custom instructions.
 *
 * Compile: riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -o test_cfu test_cfu.c
 *
 * CUSTOM_0 encoding: funct7[31:25] | rs2[24:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | 0001011
 * We use funct3 as function_id (3 bits = 8 functions).
 */

#include <stdint.h>

/* Inline assembly for CUSTOM_0 instruction.
 * .insn r CUSTOM_0, funct3, funct7, rd, rs1, rs2
 */
#define CFU_R(funct3, funct7, rd, rs1, rs2) \
    __asm__ volatile (".insn r 0x0B, %1, %2, %0, %3, %4" \
        : "=r"(rd) : "i"(funct3), "i"(funct7), "r"(rs1), "r"(rs2))

/* Single-operand variant (rs2 = x0) */
#define CFU_R1(funct3, rd, rs1) \
    __asm__ volatile (".insn r 0x0B, %1, 0, %0, %2, x0" \
        : "=r"(rd) : "i"(funct3), "r"(rs1))

/* Function wrappers */
static inline uint32_t hw_countones(uint32_t x) {
    uint32_t r; CFU_R1(0, r, x); return r;
}

static inline uint32_t hw_redxor(uint32_t x) {
    uint32_t r; CFU_R1(1, r, x); return r;
}

static inline uint32_t hw_onehot(uint32_t x) {
    uint32_t r; CFU_R1(2, r, x); return r;
}

static inline uint32_t hw_onehot0(uint32_t x) {
    uint32_t r; CFU_R1(3, r, x); return r;
}

static inline uint32_t hw_bswap32(uint32_t x) {
    uint32_t r; CFU_R1(4, r, x); return r;
}

static inline uint32_t hw_bitreverse8(uint32_t x) {
    uint32_t r; CFU_R1(5, r, x); return r;
}

static inline uint32_t hw_div(uint32_t a, uint32_t b) {
    uint32_t r; CFU_R(6, 0, r, a, b); return r;
}

static inline uint32_t hw_mod(uint32_t a, uint32_t b) {
    uint32_t r; CFU_R(7, 0, r, a, b); return r;
}

/* Minimal test — would print via UART on real hardware */
volatile uint32_t test_result;

int main() {
    test_result = hw_countones(0xFFFFFFFF);   /* expect 32 */
    test_result = hw_countones(0xAAAAAAAA);   /* expect 16 */
    test_result = hw_redxor(0x00000001);      /* expect 1 */
    test_result = hw_redxor(0x00000003);      /* expect 0 */
    test_result = hw_onehot(0x00000010);      /* expect 1 */
    test_result = hw_onehot(0x00000003);      /* expect 0 */
    test_result = hw_bswap32(0x12345678);     /* expect 0x78563412 */
    test_result = hw_div(100, 10);            /* expect 10 */
    test_result = hw_div(100, 0);             /* expect 0 */
    test_result = hw_mod(7, 2);              /* expect 1 */
    return 0;
}
