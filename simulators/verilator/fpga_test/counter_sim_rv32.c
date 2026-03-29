/* counter_sim_rv32.c — Verilator counter model for VexRiscv on FPGA.
 *
 * Writes results to I/O registers at 0xF0000000 so the Atom can read them
 * via PCIe. Signals completion by writing to 0xF0000004.
 *
 * Build:
 *   riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 \
 *     -T fpga.ld -nostdlib -o counter_sim_rv32.elf counter_sim_rv32.c
 */
#include <stdint.h>

/* I/O registers (memory-mapped, from VexRiscv perspective) */
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)
#define IO_RESULT3  (*(volatile uint32_t*)0xF0000010)

typedef struct {
    uint8_t clk, reset, enable, count, overflow, prev_clk;
} counter_state_t;

void counter_eval(counter_state_t *s) {
    if (s->clk && !s->prev_clk) {
        uint8_t new_count = s->count;
        if (s->reset) new_count = 0;
        else if (s->enable) new_count = s->count + 1;
        s->count = new_count;
    }
    s->prev_clk = s->clk;
    s->overflow = (s->count == 0xFF) & s->enable;
}

void _start(void) {
    counter_state_t s = {0, 0, 0, 0, 0, 0};

    /* Reset */
    s.reset = 1;
    s.clk = 0; counter_eval(&s);
    s.clk = 1; counter_eval(&s);
    s.clk = 0; counter_eval(&s);
    IO_RESULT0 = s.count;  /* expect 0 */

    /* Count 10 */
    s.reset = 0; s.enable = 1;
    for (int i = 0; i < 10; i++) {
        s.clk = 1; counter_eval(&s);
        s.clk = 0; counter_eval(&s);
    }
    IO_RESULT1 = s.count;  /* expect 10 */

    /* Count to 256 (wraps to 0) */
    for (int i = 10; i < 256; i++) {
        s.clk = 1; counter_eval(&s);
        s.clk = 0; counter_eval(&s);
    }
    IO_RESULT2 = s.count;  /* expect 0 */

    /* 1000 more cycles */
    for (int i = 0; i < 1000; i++) {
        s.clk = 1; counter_eval(&s);
        s.clk = 0; counter_eval(&s);
    }
    IO_RESULT3 = s.count;  /* expect 232 (1000 % 256) */

    /* Signal done */
    IO_DONE = 1;

    /* Halt */
    while (1);
}
