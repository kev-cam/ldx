// mesh_daemon.c — A53 host daemon for the 5×5 mesh.
//
// Loads `universal.bin` into all 25 cores' BRAMs, releases them,
// polls the 20 boundary endpoints, parses headers, prints arg-1 of any
// FN_LOG message (op=fire fn=1).
//
// Build: aarch64-linux-gnu-gcc -static -O2 -Wall -o mesh_daemon mesh_daemon.c
// Run on ZCU104: sudo ./mesh_daemon universal.bin

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LDX_BASE      0xA0000000UL
#define LDX_SIZE      0x20000U          // 128 KB

#define MAGIC_OFF     0x19F00
#define CTRL_OFF      0x19000
#define EP_BASE       0x19100
#define EP_STRIDE     0x10
#define EP_PUSH_DATA   0x0
#define EP_PUSH_STAT   0x4
#define EP_POP_DATA    0x8
#define EP_POP_STAT    0xC

#define N             5
#define NEPS          (4*N)
#define MAGIC_VAL     0x4C445834u
#define FN_LOG        1

#define HDR_DEST_X(h) (((h) >> 29) & 7u)
#define HDR_DEST_Y(h) (((h) >> 26) & 7u)
#define HDR_SRC_X(h)  (((h) >> 23) & 7u)
#define HDR_SRC_Y(h)  (((h) >> 20) & 7u)
#define HDR_OP(h)     (((h) >> 18) & 3u)
#define HDR_FN(h)     (((h) >> 10) & 0xFFu)
#define HDR_ARGC(h)   (((h) >>  7) & 7u)
#define HDR_TAG(h)    ( (h)        & 0x7Fu)

static volatile uint32_t *regs;
static inline uint32_t rd(unsigned off) { return regs[off >> 2]; }
static inline void     wr(unsigned off, uint32_t v) { regs[off >> 2] = v; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <firmware.bin>\n", argv[0]); return 1; }

    int fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem < 0) { perror("/dev/mem"); return 1; }
    regs = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd_mem, LDX_BASE);
    if (regs == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t magic = rd(MAGIC_OFF);
    if (magic != MAGIC_VAL) {
        fprintf(stderr, "bad magic 0x%08x (want 0x%08x)\n", magic, MAGIC_VAL);
        return 1;
    }
    fprintf(stderr, "[mesh] magic OK\n");

    // Hold all cores in reset
    wr(CTRL_OFF, 0x01FFFFFFu);

    // Load firmware
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz > 4096) { fprintf(stderr, "firmware too large: %ld\n", sz); return 1; }
    uint8_t buf[4096] = {0};
    if (fread(buf, 1, sz, f) != (size_t)sz) { perror("fread"); return 1; }
    fclose(f);

    fprintf(stderr, "[mesh] loading %ld bytes × 25 cores ...\n", sz);
    for (unsigned c = 0; c < N*N; c++) {
        unsigned core_base = c * 0x1000;
        for (long i = 0; i < (sz + 3) / 4; i++) {
            uint32_t w = (uint32_t)buf[i*4+0]
                       | ((uint32_t)buf[i*4+1] << 8)
                       | ((uint32_t)buf[i*4+2] << 16)
                       | ((uint32_t)buf[i*4+3] << 24);
            wr(core_base + i*4, w);
        }
    }
    fprintf(stderr, "[mesh] load done; releasing all cores\n");
    wr(CTRL_OFF, 0);

    // Poll endpoints
    fprintf(stderr, "[mesh] polling 20 boundary endpoints (Ctrl-C to stop) ...\n");
    unsigned reports = 0;
    for (;;) {
        for (unsigned ep = 0; ep < NEPS; ep++) {
            unsigned base = EP_BASE + ep * EP_STRIDE;
            if (rd(base + EP_POP_STAT) & 1u) continue;  // empty
            uint32_t hdr = rd(base + EP_POP_DATA);
            unsigned argc = HDR_ARGC(hdr);
            uint32_t args[8] = {0};
            for (unsigned i = 0; i < argc; i++) {
                while (rd(base + EP_POP_STAT) & 1u) { }
                args[i] = rd(base + EP_POP_DATA);
            }
            fprintf(stderr,
                    "[ep%02u] hdr=0x%08x  dst=(%u,%u) src=(%u,%u) op=%u fn=%u argc=%u tag=%u",
                    ep, hdr,
                    HDR_DEST_X(hdr), HDR_DEST_Y(hdr),
                    HDR_SRC_X(hdr),  HDR_SRC_Y(hdr),
                    HDR_OP(hdr),     HDR_FN(hdr),
                    argc,            HDR_TAG(hdr));
            for (unsigned i = 0; i < argc; i++)
                fprintf(stderr, "  arg%u=0x%08x (%u)", i, args[i], args[i]);
            fprintf(stderr, "\n");
            reports++;
            if (HDR_FN(hdr) == FN_LOG && argc >= 1) {
                printf("FN_LOG: %u\n", args[0]);
                fflush(stdout);
            }
        }
    }
    return 0;
}
