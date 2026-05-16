// cfu_test.c — exercise each CFU function from RV32I, send results to host
// via the mailbox. Host prints them; we compare against expected goldens.

#define MBOX_DATA   (*(volatile unsigned int *)0xF0000000)
#define MBOX_STATUS (*(volatile unsigned int *)0xF0000004)

static void post(unsigned int v) {
    MBOX_DATA = v;
    while (MBOX_STATUS & 1u) { }
}

// CUSTOM_0 opcode = 0x0B; funct3 selects function 0..7.
#define CFU(fid, a, b) ({                                                 \
    unsigned int _r;                                                      \
    asm volatile (".insn r 0x0B, " #fid ", 0x00, %0, %1, %2"              \
                  : "=r"(_r) : "r"(a), "r"(b));                           \
    _r;                                                                   \
})

void main(void) {
    post(CFU(0, 0xDEADBEEFu, 0));         // popcount(0xDEADBEEF) = 24
    post(CFU(1, 0xDEADBEEFu, 0));         // parity (^0xDEADBEEF) = 0
    post(CFU(2, 0x00000010u, 0));         // onehot(0x10) = 1
    post(CFU(3, 0x00000003u, 0));         // onehot0(0x3) = 0
    post(CFU(4, 0x11223344u, 0));         // bswap = 0x44332211
    post(CFU(5, 0x000000A5u, 0));         // bitrev8 = 0xA5
    post(CFU(6, 100u, 7u));               // div 100/7 = 14
    post(CFU(7, 100u, 7u));               // mod 100%7 = 2
    post(CFU(6, 42u, 0u));                // safe div by zero -> 0
    for (;;) { }
}
