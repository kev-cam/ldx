// v4cfu_host.c — A53-side driver for v4cfu_smoke.bin. Loads firmware into
// all cores, releases reset, reads 8 result words from (1,1)'s W boundary
// endpoint, compares against expected values.

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LDX_BASE   0xA0000000UL
#define LDX_SIZE   0x20000U
#define MAGIC_OFF  0x19F00
#define CTRL_OFF   0x19000
#define EP_BASE    0x19100
#define EP_STRIDE  0x10
#define EP_PUSH    0x0
#define EP_PUSHST  0x4
#define EP_POP     0x8
#define EP_POPST   0xC
#define N          5
#define MAGIC_VAL  0x4C445834u

static volatile uint32_t *regs;
static inline uint32_t rd(unsigned off) { return regs[off >> 2]; }
static inline void     wr(unsigned off, uint32_t v) { regs[off >> 2] = v; }

int main(int argc, char **argv) {
    const char *fw = (argc >= 2) ? argv[1] : "v4cfu_smoke.bin";

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    void *p = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LDX_BASE);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    regs = (volatile uint32_t *)p;
    if (rd(MAGIC_OFF) != MAGIC_VAL) {
        fprintf(stderr, "bad magic 0x%08x\n", rd(MAGIC_OFF)); return 1;
    }

    wr(CTRL_OFF, 0x01FFFFFFu);

    FILE *f = fopen(fw, "rb");
    if (!f) { perror(fw); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    if (sz > 4096) { fprintf(stderr, "fw too large: %ld\n", sz); return 1; }
    uint8_t buf[4096] = {0};
    if (fread(buf, 1, sz, f) != (size_t)sz) { perror("fread"); return 1; }
    fclose(f);
    for (unsigned c = 0; c < N*N; c++) {
        unsigned base = c * 0x1000;
        for (long i = 0; i < (sz + 3) / 4; i++) {
            uint32_t w = (uint32_t)buf[i*4]
                       | ((uint32_t)buf[i*4+1] << 8)
                       | ((uint32_t)buf[i*4+2] << 16)
                       | ((uint32_t)buf[i*4+3] << 24);
            wr(base + i*4, w);
        }
    }

    wr(CTRL_OFF, 0);

    // (1,1) pushes to W boundary endpoint = 3*N + 0 = 15
    unsigned eb = EP_BASE + 15 * EP_STRIDE;

    static const uint32_t expected[8] = {
        0xDEADBEEFu ^ 0xCAFEBABEu,
        0xDEADBEEFu & 0xCAFEBABEu,
        0xDEADBEEFu | 0xCAFEBABEu,
        ~0xDEADBEEFu,
        (uint32_t)(0xDEADBEEFu + 0xCAFEBABEu),
        1u,
        (uint32_t)(0xFFFFFFFFu + 0x80000001u),
        1u
    };
    static const char *names[8] = {
        "xor(DEADBEEF,CAFEBABE)", "and(DEADBEEF,CAFEBABE)",
        "or (DEADBEEF,CAFEBABE)", "not(DEADBEEF)         ",
        "add(DEADBEEF,CAFEBABE)", "addcout(.. above)     ",
        "add(FFFFFFFF,80000001)", "addcout(.. above)     "
    };

    int fails = 0;
    for (int i = 0; i < 8; i++) {
        while (rd(eb + EP_POPST) & 1u) { }
        uint32_t got = rd(eb + EP_POP);
        int ok = (got == expected[i]);
        printf("  [%d] %s = 0x%08x  want 0x%08x  %s\n",
               i, names[i], got, expected[i], ok ? "OK" : "BAD");
        if (!ok) fails++;
    }
    printf("\n%d fails\n", fails);
    return fails ? 1 : 0;
}
