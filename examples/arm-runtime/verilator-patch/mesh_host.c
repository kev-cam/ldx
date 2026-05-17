// mesh_host.c — wander_call from the A53 into the 5x5 mesh.
//
// Injects requests on the west boundary (row dy of the inner grid maps to
// flat endpoint 3*N + (dy-1)). The mesh's XY-routed forwarder picks up
// dest=(dx,dy), runs the dispatcher there, sends OP_RETURN back to
// src=(0,dy) which routes straight west out the same edge port.

#include "mesh_host.h"

#include <fcntl.h>
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
#define NEPS       (4 * N)
#define MAGIC_VAL  0x4C445834u

static volatile uint32_t *regs = NULL;
static unsigned next_tag = 1;

static inline uint32_t rd(unsigned off)         { return regs[off >> 2]; }
static inline void     wr(unsigned off, uint32_t v) { regs[off >> 2] = v; }

static inline uint32_t mk_hdr(unsigned dx, unsigned dy,
                              unsigned sx, unsigned sy,
                              unsigned op, unsigned fn,
                              unsigned argc, unsigned tag) {
    return ((dx   & 7u)   << 29) | ((dy   & 7u)   << 26)
         | ((sx   & 7u)   << 23) | ((sy   & 7u)   << 20)
         | ((op   & 3u)   << 18) | ((fn   & 0xFFu)<< 10)
         | ((argc & 7u)   <<  7) |  (tag  & 0x7Fu);
}
#define HDR_OP(h)   (((h) >> 18) & 3u)
#define HDR_TAG(h)  ( (h)        & 0x7Fu)
#define HDR_ARGC(h) (((h) >>  7) & 7u)

#define OP_CALL    1
#define OP_RETURN  2

static inline unsigned ep_west_row(unsigned y) { return 3*N + (y - 1); }

int mesh_init(const char *fw_path) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return -1; }
    void *p = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LDX_BASE);
    if (p == MAP_FAILED) { perror("mmap"); return -1; }
    regs = (volatile uint32_t *)p;

    uint32_t m = rd(MAGIC_OFF);
    if (m != MAGIC_VAL) {
        fprintf(stderr, "mesh_init: bad magic 0x%08x\n", m);
        return -1;
    }

    wr(CTRL_OFF, 0x01FFFFFFu);

    FILE *f = fopen(fw_path, "rb");
    if (!f) { perror(fw_path); return -1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz > 4096) { fprintf(stderr, "fw too large: %ld\n", sz); fclose(f); return -1; }
    uint8_t buf[4096] = {0};
    if (fread(buf, 1, sz, f) != (size_t)sz) { perror("fread"); fclose(f); return -1; }
    fclose(f);

    for (unsigned c = 0; c < N * N; c++) {
        unsigned base = c * 0x1000;
        for (long i = 0; i < (sz + 3) / 4; i++) {
            uint32_t w = (uint32_t)buf[i*4+0]
                       | ((uint32_t)buf[i*4+1] << 8)
                       | ((uint32_t)buf[i*4+2] << 16)
                       | ((uint32_t)buf[i*4+3] << 24);
            wr(base + i*4, w);
        }
    }

    wr(CTRL_OFF, 0);

    // Drain stale boundary traffic from any previous run.
    for (unsigned ep = 0; ep < NEPS; ep++) {
        unsigned eb = EP_BASE + ep * EP_STRIDE;
        while (!(rd(eb + EP_POPST) & 1u)) (void)rd(eb + EP_POP);
    }
    return 0;
}

uint32_t mesh_call(unsigned dx, unsigned dy, unsigned fn,
                   unsigned argc, const uint32_t *args) {
    unsigned tag = (next_tag++) & 0x7Fu;
    if (tag == 0) tag = 1;
    unsigned eb = EP_BASE + ep_west_row(dy) * EP_STRIDE;

    uint32_t hdr = mk_hdr(dx, dy, 0u, dy, OP_CALL, fn, argc, tag);

    while (rd(eb + EP_PUSHST) & 1u) { }
    wr(eb + EP_PUSH, hdr);
    for (unsigned i = 0; i < argc; i++) {
        while (rd(eb + EP_PUSHST) & 1u) { }
        wr(eb + EP_PUSH, args[i]);
    }

    for (;;) {
        while (rd(eb + EP_POPST) & 1u) { }
        uint32_t rh = rd(eb + EP_POP);
        unsigned ac = HDR_ARGC(rh);
        if (HDR_OP(rh) == OP_RETURN && HDR_TAG(rh) == tag) {
            uint32_t v = 0;
            if (ac >= 1) {
                while (rd(eb + EP_POPST) & 1u) { }
                v = rd(eb + EP_POP);
            }
            for (unsigned i = 1; i < ac; i++) {
                while (rd(eb + EP_POPST) & 1u) { }
                (void)rd(eb + EP_POP);
            }
            return v;
        }
        for (unsigned i = 0; i < ac; i++) {
            while (rd(eb + EP_POPST) & 1u) { }
            (void)rd(eb + EP_POP);
        }
    }
}

void mesh_shutdown(void) {
    if (regs && regs != (void *)-1) {
        wr(CTRL_OFF, 0x01FFFFFFu);
        munmap((void *)regs, LDX_SIZE);
        regs = NULL;
    }
}
