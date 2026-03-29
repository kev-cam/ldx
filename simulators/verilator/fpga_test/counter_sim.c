/* counter_sim.c — Hand-extracted Verilator model of counter.v.
 *
 * This is what Verilator's generated C++ does, reduced to plain C.
 * The actual logic from Vcounter___024root__DepSet_he26a92aa__0.cpp:
 *
 *   combinational: overflow = (count == 0xFF) & enable
 *   sequential:    if (reset) count = 0; else if (enable) count++;
 *
 * For a real Verilator-on-FPGA flow, this extraction would be automated.
 */
#include <stdint.h>

/* Model state — matches Vcounter___024root */
typedef struct {
    uint8_t clk;
    uint8_t reset;
    uint8_t enable;
    uint8_t count;
    uint8_t overflow;
    uint8_t prev_clk;
} counter_state_t;

/* Combinational evaluation */
static void counter_comb(counter_state_t *s) {
    s->overflow = (s->count == 0xFF) & s->enable;
}

/* Sequential evaluation (on posedge clk) */
static void counter_seq(counter_state_t *s) {
    uint8_t new_count = s->count;
    if (s->reset)
        new_count = 0;
    else if (s->enable)
        new_count = s->count + 1;
    s->count = new_count;
    counter_comb(s);
}

/* Full eval: detect clock edge, run combinational + sequential */
static void counter_eval(counter_state_t *s) {
    /* posedge detection */
    if (s->clk && !s->prev_clk) {
        counter_seq(s);
    }
    s->prev_clk = s->clk;
    counter_comb(s);
}

/* Raw syscalls for bare-metal rv32/rv64 */
static long sys_write(int fd, const void *buf, long len) {
    register long a0 __asm__("a0") = fd;
    register long a1 __asm__("a1") = (long)buf;
    register long a2 __asm__("a2") = len;
    register long a7 __asm__("a7") = 64;
    __asm__ volatile ("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return a0;
}

static void sys_exit(int code) {
    register long a0 __asm__("a0") = code;
    register long a7 __asm__("a7") = 93;
    __asm__ volatile ("ecall" : : "r"(a0), "r"(a7));
    __builtin_unreachable();
}

static void puts_raw(const char *s) {
    long len = 0;
    const char *p = s;
    while (*p++) len++;
    sys_write(1, s, len);
}

static void print_u32(uint32_t v) {
    char buf[12];
    int i = 10;
    buf[11] = 0;
    if (v == 0) { buf[i--] = '0'; }
    else { while (v) { buf[i--] = '0' + (v % 10); v /= 10; } }
    puts_raw(&buf[i + 1]);
}

static int pass = 0, fail = 0;

static void check(const char *name, uint32_t got, uint32_t expected) {
    if (got == expected) {
        pass++;
    } else {
        puts_raw("FAIL ");
        puts_raw(name);
        puts_raw(": got ");
        print_u32(got);
        puts_raw(", expected ");
        print_u32(expected);
        puts_raw("\n");
        fail++;
    }
}

int main() {
    pass = 0; fail = 0;
    counter_state_t s = {0, 0, 0, 0, 0, 0};

    /* Reset pulse */
    s.reset = 1;
    s.clk = 0; counter_eval(&s);
    s.clk = 1; counter_eval(&s);
    s.clk = 0; counter_eval(&s);
    check("after reset", s.count, 0);

    /* Release reset, enable counting */
    s.reset = 0;
    s.enable = 1;

    /* Count to 10 */
    for (int i = 0; i < 10; i++) {
        s.clk = 1; counter_eval(&s);
        s.clk = 0; counter_eval(&s);
    }
    check("count after 10 cycles", s.count, 10);

    /* Count to 255 */
    for (int i = 10; i < 255; i++) {
        s.clk = 1; counter_eval(&s);
        s.clk = 0; counter_eval(&s);
    }
    check("count at 255", s.count, 255);
    check("overflow at 255", s.overflow, 1);

    /* Count wraps to 0 */
    s.clk = 1; counter_eval(&s);
    s.clk = 0; counter_eval(&s);
    check("count wraps to 0", s.count, 0);
    check("overflow clears", s.overflow, 0);

    /* Run 1000 more cycles */
    for (int i = 0; i < 1000; i++) {
        s.clk = 1; counter_eval(&s);
        s.clk = 0; counter_eval(&s);
    }
    check("count after 1000 more", s.count, (1000 & 0xFF));

    print_u32(pass);
    puts_raw(" passed, ");
    print_u32(fail);
    puts_raw(" failed\n");
    if (fail == 0) puts_raw("ALL PASS\n");

    sys_exit(fail);
}

void __attribute__((naked)) _start(void) {
    __asm__ volatile (
        ".option push\n"
        ".option norelax\n"
        "la gp, __global_pointer$\n"
        ".option pop\n"
        "la t0, __bss_start\n"
        "la t1, _end\n"
        "1: bgeu t0, t1, 2f\n"
        "sd zero, 0(t0)\n"
        "addi t0, t0, 8\n"
        "j 1b\n"
        "2:\n"
        "call main\n"
        "li a7, 93\n"
        "ecall\n"
    );
}
