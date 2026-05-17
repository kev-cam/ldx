// sha_pipe_host.c — A53 driver for the 5-stage SHA-256 pipeline.
//
// Pushes one pipeline message per hash into the west boundary at row 3,
// reads 8-word digests out of the east boundary at row 3.
// Wire format on the pipe (32 words):
//   init_state[0..7], a_h[0..7], w_ring[0..15]
// where a_h is seeded equal to init_state for round 0.

#include <fcntl.h>
#include <pthread.h>
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
static unsigned ep_east_row(unsigned y) { return     N + (y - 1); }

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

static inline void push_w(unsigned eb, uint32_t v) {
    while (rd(eb + EP_PUSHST) & 1u) { }
    wr(eb + EP_PUSH, v);
}
static inline uint32_t pop_w(unsigned eb) {
    while (rd(eb + EP_POPST) & 1u) { }
    return rd(eb + EP_POP);
}

int main(int argc, char **argv) {
    const char *fw = (argc >= 2) ? argv[1] : "sha_stage.bin";
    unsigned iters = (argc >= 3) ? (unsigned)strtoul(argv[2], NULL, 0) : 1;
    // Pipeline topology: "5" = 5-stage row y=3 (default), "25" = full mesh
    int topology = (argc >= 4) ? atoi(argv[3]) : 5;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    regs = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LDX_BASE);
    if (regs == MAP_FAILED) { perror("mmap"); return 1; }
    if (rd(MAGIC_OFF) != MAGIC_VAL) { fprintf(stderr, "bad magic\n"); return 1; }

    wr(CTRL_OFF, 0x01FFFFFFu);
    if (load_fw_all(fw) < 0) return 1;
    wr(CTRL_OFF, 0);

    for (unsigned ep = 0; ep < 4 * N; ep++) {
        unsigned eb = EP_BASE + ep * EP_STRIDE;
        while (!(rd(eb + EP_POPST) & 1u)) (void)rd(eb + EP_POP);
    }

    unsigned ep_in, ep_out;
    if (topology == 25) {
        ep_in  = EP_BASE + ep_west_row(1) * EP_STRIDE;   // (1,1) west
        ep_out = EP_BASE + ep_east_row(5) * EP_STRIDE;   // (5,5) east
    } else {
        ep_in  = EP_BASE + ep_west_row(3) * EP_STRIDE;
        ep_out = EP_BASE + ep_east_row(3) * EP_STRIDE;
    }
    printf("topology=%d  ep_in=0x%05x  ep_out=0x%05x\n", topology, ep_in, ep_out);

    static const uint32_t init_state[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
    };
    static const uint32_t block[16] = {
        0x61626380u, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0x00000018u
    };
    static const uint32_t expected[8] = {
        0xba7816bfu, 0x8f01cfeau, 0x414140deu, 0x5dae2223u,
        0xb00361a3u, 0x96177a9cu, 0xb410ff61u, 0xf20015adu
    };

    // Producer/consumer threads: producer keeps the pipeline fed, consumer
    // drains digests. Concurrent push/pop avoids the deadlock where the
    // host blocks pushing while stage 4's tx FIFO is full waiting on a pop.
    struct ctx {
        unsigned ep_in, ep_out;
        unsigned iters;
        const uint32_t *init_state, *block, *expected;
        int fails;
    };
    static __thread int unused_marker;  // suppress unused warning
    (void)unused_marker;

    struct ctx C = {
        .ep_in = ep_in, .ep_out = ep_out,
        .iters = iters,
        .init_state = init_state, .block = block, .expected = expected,
        .fails = 0
    };

    void *producer(void *arg) {
        struct ctx *c = arg;
        // 24-word wire format: a_h (= init_state for round 0) + w_ring (= block)
        for (unsigned it = 0; it < c->iters; it++) {
            for (int i = 0; i < 8;  i++) push_w(c->ep_in, c->init_state[i]);
            for (int i = 0; i < 16; i++) push_w(c->ep_in, c->block[i]);
        }
        return NULL;
    }
    void *consumer(void *arg) {
        struct ctx *c = arg;
        for (unsigned it = 0; it < c->iters; it++) {
            uint32_t a_h[8], out[8];
            for (int i = 0; i < 8; i++) a_h[i] = pop_w(c->ep_out);
            // Host applies the final SHA-256 add: digest = init_state + a..h
            for (int i = 0; i < 8; i++) out[i] = c->init_state[i] + a_h[i];

            int show = (it == 0 || it == c->iters - 1);
            for (int i = 0; i < 8; i++) {
                int ok = out[i] == c->expected[i];
                if (!ok) __sync_fetch_and_add(&c->fails, 1);
                if (show) printf("  hash[%d] = 0x%08x  %s\n",
                                 i, out[i], ok ? "OK" : "BAD");
            }
        }
        return NULL;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    pthread_t pt, ct;
    pthread_create(&pt, NULL, producer, &C);
    pthread_create(&ct, NULL, consumer, &C);
    pthread_join(pt, NULL);
    pthread_join(ct, NULL);
    int fails = C.fails;

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    double per_hash_us = (ns / (double)iters) / 1e3;
    printf("\n%u hashes in %.3f ms  →  %.2f us/hash  →  %.2f kH/s  (%d fails)\n",
           iters, ns / 1e6, per_hash_us, 1e3 / per_hash_us, fails);
    return fails ? 1 : 0;
}
