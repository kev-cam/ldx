// sha_stage25.c — 25-stage SHA-256 pipeline across the full 5×5 mesh.
//
// Topology (serpentine path; arrows show data flow direction):
//
//   y=5  ┌─►─►─►─►─┐ (stages 20-24, exits east at (5,5))
//   y=4  └─◄─◄─◄─◄─┘ (stages 19-15)
//   y=3  ┌─►─►─►─►─┐ (stages 10-14)
//   y=2  └─◄─◄─◄─◄─┘ (stages  9- 5)
//   y=1  ►─►─►─►─►─┘ (stages  0- 4; enters west at (1,1))
//
// Round split is 14 stages × 3 rounds + 11 stages × 2 rounds = 64.

#include "mesh.h"

#define NSTAGES        25
#define TOTAL_ROUNDS   64

// Stage-by-(gx, gy)
static const uint8_t STAGE_OF[5][5] = {
    /* gx=0 */ {  0,  9, 10, 19, 20 },
    /* gx=1 */ {  1,  8, 11, 18, 21 },
    /* gx=2 */ {  2,  7, 12, 17, 22 },
    /* gx=3 */ {  3,  6, 13, 16, 23 },
    /* gx=4 */ {  4,  5, 14, 15, 24 },
};

// Input direction (read FIFO) per stage
static const uint8_t IN_DIR_OF[NSTAGES] = {
    DIR_W, DIR_W, DIR_W, DIR_W, DIR_W,   //  0- 4 row y=1 west→east
    DIR_S, DIR_E, DIR_E, DIR_E, DIR_E,   //  5- 9 row y=2 east→west (5 reads S from (5,1))
    DIR_S, DIR_W, DIR_W, DIR_W, DIR_W,   // 10-14 row y=3 west→east (10 reads S from (1,2))
    DIR_S, DIR_E, DIR_E, DIR_E, DIR_E,   // 15-19 row y=4 east→west (15 reads S from (5,3))
    DIR_S, DIR_W, DIR_W, DIR_W, DIR_W,   // 20-24 row y=5 west→east (20 reads S from (1,4))
};

// Output direction (write FIFO) per stage
static const uint8_t OUT_DIR_OF[NSTAGES] = {
    DIR_E, DIR_E, DIR_E, DIR_E, DIR_N,   //  0- 4 last writes N to (5,2)
    DIR_W, DIR_W, DIR_W, DIR_W, DIR_N,   //  5- 9 last writes N to (1,3)
    DIR_E, DIR_E, DIR_E, DIR_E, DIR_N,   // 10-14 last writes N to (5,4)
    DIR_W, DIR_W, DIR_W, DIR_W, DIR_N,   // 15-19 last writes N to (1,5)
    DIR_E, DIR_E, DIR_E, DIR_E, DIR_E,   // 20-24 final writes E to boundary
};

// Precomputed round boundaries for NSTAGES=25 (RV32I has no DIV).
// 14 stages of 3 rounds + 11 stages of 2 rounds = 64.
static const uint8_t STAGE_R[NSTAGES + 1] = {
     0,  3,  6,  9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39,
    42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64
};

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
    unsigned gx = my_x() - 1;
    unsigned gy = my_y() - 1;
    if (gx >= 5 || gy >= 5) { for (;;) { } }
    unsigned stage = STAGE_OF[gx][gy];
    int in_dir  = IN_DIR_OF[stage];
    int out_dir = OUT_DIR_OF[stage];
    int r0 = STAGE_R[stage];
    int r1 = STAGE_R[stage + 1];

    uint32_t init_state[8];
    uint32_t a_h[8];
    uint32_t w_ring[16];

    for (;;) {
        read_dir(in_dir, init_state, 8);
        read_dir(in_dir, a_h,        8);
        read_dir(in_dir, w_ring,    16);

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
            uint32_t out[8];
            for (int i = 0; i < 8; i++) out[i] = init_state[i] + a_h[i];
            write_dir(out_dir, out, 8);
        } else {
            write_dir(out_dir, init_state, 8);
            write_dir(out_dir, a_h,        8);
            write_dir(out_dir, w_ring,    16);
        }
    }
}
