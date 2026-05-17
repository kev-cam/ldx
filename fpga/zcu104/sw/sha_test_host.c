// sha_test_host.c — A53 host for sha_pipeline.c worker.
//
// Loads sha_pipeline.bin into the mesh, pushes (state, block) to the
// W-edge endpoint at row 3 (softcore (1,3)), reads back 8 words of hash,
// validates against SHA-256("abc").
//
// Build: aarch64-linux-gnu-gcc -static -O2 -Wall -o sha_test_host sha_test_host.c

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
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

static unsigned ep_west_row(unsigned y) { return 3 * N + (y - 1); }

static int load_fw_all(const char *fw_path) {
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
    return 0;
}

static void push_word(unsigned eb, uint32_t v) {
    while (rd(eb + EP_PUSHST) & 1u) { }
    wr(eb + EP_PUSH, v);
}

static uint32_t pop_word(unsigned eb) {
    while (rd(eb + EP_POPST) & 1u) { }
    return rd(eb + EP_POP);
}

int main(int argc, char **argv) {
    const char *fw = (argc >= 2) ? argv[1] : "sha_pipeline.bin";
    unsigned iters = (argc >= 3) ? (unsigned)strtoul(argv[2], NULL, 0) : 1;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    regs = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LDX_BASE);
    if (regs == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t magic = rd(MAGIC_OFF);
    if (magic != MAGIC_VAL) { fprintf(stderr, "bad magic 0x%08x\n", magic); return 1; }

    // Hold cores, load firmware, release
    wr(CTRL_OFF, 0x01FFFFFFu);
    if (load_fw_all(fw) < 0) return 1;
    wr(CTRL_OFF, 0);

    // Drain any stale boundary traffic
    for (unsigned ep = 0; ep < 4 * N; ep++) {
        unsigned eb = EP_BASE + ep * EP_STRIDE;
        while (!(rd(eb + EP_POPST) & 1u)) (void)rd(eb + EP_POP);
    }

    // Worker at (1, 3): host injects on W boundary endpoint 17
    unsigned eb = EP_BASE + ep_west_row(3) * EP_STRIDE;

    static const uint32_t init_state[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
    };
    // Padded "abc" (3 bytes, message-length = 24 bits)
    static const uint32_t block[16] = {
        0x61626380u, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x00000018u
    };
    static const uint32_t expected[8] = {
        0xba7816bfu, 0x8f01cfeau, 0x414140deu, 0x5dae2223u,
        0xb00361a3u, 0x96177a9cu, 0xb410ff61u, 0xf20015adu
    };

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    int fails = 0;
    for (unsigned it = 0; it < iters; it++) {
        for (int i = 0; i < 8;  i++) push_word(eb, init_state[i]);
        for (int i = 0; i < 16; i++) push_word(eb, block[i]);
        uint32_t out[8];
        for (int i = 0; i < 8;  i++) out[i] = pop_word(eb);

        if (it == 0 || it == iters - 1) {
            for (int i = 0; i < 8; i++) {
                int ok = out[i] == expected[i];
                printf("  hash[%d] = 0x%08x  %s\n", i, out[i], ok ? "OK" : "BAD");
                if (!ok) fails++;
            }
        } else {
            for (int i = 0; i < 8; i++) if (out[i] != expected[i]) fails++;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    double per_hash_us = (ns / (double)iters) / 1e3;
    printf("\n%u hashes in %.3f ms  →  %.2f us/hash  →  %.2f kH/s\n",
           iters, ns / 1e6, per_hash_us, 1e3 / per_hash_us);

    return fails ? 1 : 0;
}
