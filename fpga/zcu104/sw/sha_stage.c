// sha_stage.c — pipelined SHA-256 worker for the ldx mesh.
//
// Every softcore runs the same binary. Only cores at row y=3 are on the
// data path; stage index = my_x - 1, so the 5 cores (1,3)..(5,3) form
// a linear pipeline. Each stage reads 32 words from its W FIFO, runs
// its rounds (rounds_per_stage ≈ 64/N), and writes 32 words to its E
// FIFO. The final stage applies the initial-state addition and emits
// the 8-word hash to E instead of the 32-word pipeline message.
//
// Wire format on the pipe (24 words):
//   a_h[0..7]    running state (a..h)
//   w_ring[0..15] W values indexed by `r%16` (so w_ring[r%16] = W[r])
// The host holds the original SHA initial state and adds it to the
// final-stage's 8-word a_h output to form the digest.

#include "mesh.h"

#define NSTAGES        5
#define TOTAL_ROUNDS  64
#define ROW            3

#define IN_DIR   DIR_W
#define OUT_DIR  DIR_E

static inline int my_stage(void) { return (int)my_x() - 1; }

// Precomputed round split for NSTAGES=5, TOTAL_ROUNDS=64 (RV32I has no DIV).
//   stage 0: rounds 0..12   (13)
//   stage 1: rounds 12..25  (13)
//   stage 2: rounds 25..38  (13)
//   stage 3: rounds 38..51  (13)
//   stage 4: rounds 51..64  (13)
static const uint8_t STAGE_R[NSTAGES + 1] = {0, 12, 25, 38, 51, 64};
static inline int stage_r0(int k) { return STAGE_R[k]; }
static inline int stage_r1(int k) { return STAGE_R[k + 1]; }

static inline void read_dir(int dir, uint32_t *dst, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        while (POP_STATUS(dir) & 1u) { }
        dst[i] = POP_DATA(dir);
    }
}
static inline void write_dir(int dir, const uint32_t *src, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        while (PUSH_STATUS(dir) & 1u) { }
        PUSH_DATA(dir) = src[i];
    }
}

static inline uint32_t rotr(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32u - n));
}

static const uint32_t K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

#define CH(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x)     (rotr(x, 2) ^ rotr(x,13) ^ rotr(x,22))
#define EP1(x)     (rotr(x, 6) ^ rotr(x,11) ^ rotr(x,25))
#define SIG0(x)    (rotr(x, 7) ^ rotr(x,18) ^ ((x) >> 3))
#define SIG1(x)    (rotr(x,17) ^ rotr(x,19) ^ ((x) >> 10))

void main(void) {
    // Off the data path: idle.
    if (my_y() != ROW || my_x() < 1 || my_x() > NSTAGES) {
        for (;;) { }
    }
    int stage = my_stage();
    int r0 = stage_r0(stage);
    int r1 = stage_r1(stage);

    uint32_t a_h[8];
    uint32_t w_ring[16];

    for (;;) {
        read_dir(IN_DIR, a_h,    8);
        read_dir(IN_DIR, w_ring, 16);

        uint32_t a = a_h[0], b = a_h[1], c = a_h[2], d = a_h[3];
        uint32_t e = a_h[4], f = a_h[5], g = a_h[6], h = a_h[7];

        for (int r = r0; r < r1; r++) {
            unsigned ri = (unsigned)r & 15u;
            uint32_t w_val;
            if (r < 16) {
                w_val = w_ring[ri];
            } else {
                uint32_t wm2  = w_ring[(ri + 14) & 15u];
                uint32_t wm7  = w_ring[(ri +  9) & 15u];
                uint32_t wm15 = w_ring[(ri +  1) & 15u];
                uint32_t wm16 = w_ring[ ri              ];
                w_val = SIG1(wm2) + wm7 + SIG0(wm15) + wm16;
                w_ring[ri] = w_val;
            }
            uint32_t t1 = h + EP1(e) + CH(e,f,g) + K[r] + w_val;
            uint32_t t2 = EP0(a) + MAJ(a,b,c);
            h = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
        }

        a_h[0] = a; a_h[1] = b; a_h[2] = c; a_h[3] = d;
        a_h[4] = e; a_h[5] = f; a_h[6] = g; a_h[7] = h;

        if (stage == NSTAGES - 1) {
            write_dir(OUT_DIR, a_h, 8);
        } else {
            write_dir(OUT_DIR, a_h,    8);
            write_dir(OUT_DIR, w_ring, 16);
        }
    }
}
