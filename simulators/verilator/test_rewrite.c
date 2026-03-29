/* test_rewrite.c — Test program for riscv_rewrite.py with Verilator functions.
 *
 * Compiled normally (no custom instructions), then riscv_rewrite.py
 * patches the call sites to use CUSTOM_0 instructions.
 *
 * Build:
 *   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -fno-inline \
 *     -o test_rewrite test_rewrite.c ldx_verilator_accel.c -nostdlib -e main
 *
 * Rewrite:
 *   python3 ../../python/riscv_rewrite.py -i test_rewrite -o test_rewrite.hw \
 *     -m cfu_mapping.json
 */
#include <stdint.h>

/* These are defined in ldx_verilator_accel.c */
extern uint32_t vl_countones_i(uint32_t lhs);
extern uint32_t vl_redxor_32(uint32_t r);
extern uint32_t vl_onehot_i(uint32_t lhs);
extern uint32_t vl_onehot0_i(uint32_t lhs);
extern uint32_t vl_bswap32(uint32_t v);
extern uint32_t vl_bitreverse8(uint32_t v);
extern uint32_t vl_div_iii(uint32_t lhs, uint32_t rhs);
extern uint32_t vl_moddiv_iii(uint32_t lhs, uint32_t rhs);

/* Store results to memory so they don't get optimized away */
volatile uint32_t results[16];

void main(void) {
    results[0] = vl_countones_i(0xFFFFFFFF);  /* 32 */
    results[1] = vl_countones_i(0xAAAAAAAA);  /* 16 */
    results[2] = vl_redxor_32(0x00000001);    /* 1 */
    results[3] = vl_redxor_32(0x00000003);    /* 0 */
    results[4] = vl_onehot_i(0x00000010);     /* 1 */
    results[5] = vl_onehot_i(0x00000003);     /* 0 */
    results[6] = vl_onehot0_i(0x00000000);    /* 1 */
    results[7] = vl_bswap32(0x12345678);      /* 0x78563412 */
    results[8] = vl_bitreverse8(0x01);        /* 0x80 */
    results[9] = vl_div_iii(100, 10);         /* 10 */
    results[10] = vl_div_iii(100, 0);         /* 0 */
    results[11] = vl_moddiv_iii(7, 2);       /* 1 */

    /* Infinite loop (bare-metal) */
    while (1);
}
