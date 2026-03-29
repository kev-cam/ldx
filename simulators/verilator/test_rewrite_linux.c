/* test_rewrite_linux.c — Linux userspace test for riscv_rewrite.py.
 *
 * Uses raw syscalls to avoid libc dependencies that rv-sim doesn't support.
 *
 * Build:
 *   riscv64-linux-gnu-gcc -O2 -fno-inline -static \
 *     -o test_rewrite_linux test_rewrite_linux.c ldx_verilator_accel.c
 *
 * Run:
 *   rv-sim test_rewrite_linux
 */
#include <stdint.h>

extern uint32_t vl_countones_i(uint32_t lhs);
extern uint32_t vl_redxor_32(uint32_t r);
extern uint32_t vl_onehot_i(uint32_t lhs);
extern uint32_t vl_onehot0_i(uint32_t lhs);
extern uint32_t vl_bswap32(uint32_t v);
extern uint32_t vl_bitreverse8(uint32_t v);
extern uint32_t vl_div_iii(uint32_t lhs, uint32_t rhs);
extern uint32_t vl_moddiv_iii(uint32_t lhs, uint32_t rhs);

/* Raw syscalls */
static long sys_write(int fd, const void *buf, long len) {
    register long a0 __asm__("a0") = fd;
    register long a1 __asm__("a1") = (long)buf;
    register long a2 __asm__("a2") = len;
    register long a7 __asm__("a7") = 64;  /* SYS_write */
    __asm__ volatile ("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return a0;
}

static void sys_exit(int code) {
    register long a0 __asm__("a0") = code;
    register long a7 __asm__("a7") = 93;  /* SYS_exit */
    __asm__ volatile ("ecall" : : "r"(a0), "r"(a7));
    __builtin_unreachable();
}

static void puts_raw(const char *s) {
    long len = 0;
    while (s[len]) len++;
    sys_write(1, s, len);
}

/* Simple decimal print */
static void print_u32(uint32_t v) {
    char buf[12];
    int i = 11;
    buf[i--] = 0;
    if (v == 0) { buf[i--] = '0'; }
    else { while (v) { buf[i--] = '0' + (v % 10); v /= 10; } }
    puts_raw(&buf[i + 1]);
}

int pass, fail;

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
    pass = 0;
    fail = 0;
    check("countones(0xFFFFFFFF)", vl_countones_i(0xFFFFFFFF), 32);
    check("countones(0xAAAAAAAA)", vl_countones_i(0xAAAAAAAA), 16);
    check("countones(0x00000001)", vl_countones_i(0x00000001), 1);
    check("countones(0x00000000)", vl_countones_i(0x00000000), 0);

    check("redxor(0x00000001)", vl_redxor_32(0x00000001), 1);
    check("redxor(0x00000003)", vl_redxor_32(0x00000003), 0);
    check("redxor(0xFFFFFFFF)", vl_redxor_32(0xFFFFFFFF), 0);

    check("onehot(0x00000010)", vl_onehot_i(0x00000010), 1);
    check("onehot(0x00000003)", vl_onehot_i(0x00000003), 0);
    check("onehot(0x00000000)", vl_onehot_i(0x00000000), 0);

    check("onehot0(0x00000000)", vl_onehot0_i(0x00000000), 1);
    check("onehot0(0x00000001)", vl_onehot0_i(0x00000001), 1);
    check("onehot0(0x00000003)", vl_onehot0_i(0x00000003), 0);

    check("bswap32(0x12345678)", vl_bswap32(0x12345678), 0x78563412);
    check("bswap32(0xDEADBEEF)", vl_bswap32(0xDEADBEEF), 0xEFBEADDE);

    check("bitreverse8(0x01)", vl_bitreverse8(0x01), 0x80);
    check("bitreverse8(0xFF)", vl_bitreverse8(0xFF), 0xFF);

    check("div(100, 10)", vl_div_iii(100, 10), 10);
    check("div(100, 0)", vl_div_iii(100, 0), 0);
    check("div(7, 2)", vl_div_iii(7, 2), 3);

    check("mod(100, 10)", vl_moddiv_iii(100, 10), 0);
    check("mod(7, 2)", vl_moddiv_iii(7, 2), 1);
    check("mod(100, 0)", vl_moddiv_iii(100, 0), 0);

    print_u32(pass);
    puts_raw(" passed, ");
    print_u32(fail);
    puts_raw(" failed\n");
    if (fail == 0) puts_raw("ALL PASS\n");

    sys_exit(fail);
    /* not reached */
    while(1);
}

/* Entry point — bypass libc.  Kernel gives us a valid sp. */
void __attribute__((naked)) _start(void) {
    __asm__ volatile (
        ".option push\n"
        ".option norelax\n"
        "la gp, __global_pointer$\n"
        ".option pop\n"
        /* zero BSS */
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
