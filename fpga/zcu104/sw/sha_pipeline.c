// sha_pipeline.c — SHA-256 worker for the ldx mesh.
//
// Single-stage variant (this file): one core runs the full 64-round
// SHA-256. It reads 8 words of state + 16 words of message block from
// its W pop FIFO, runs sha256_block, then writes the 8-word resulting
// state back to its W push FIFO.
//
// Build:
//   make sha_pipeline.bin
//
// Deploy:
//   The host loads sha_pipeline.bin into the worker core only (we
//   pick (1,3) by default). Other cores can stay in reset or run a
//   forwarder; they aren't on the data path.

#include "mesh.h"

static inline void read_w(uint32_t *dst, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        while (POP_STATUS(DIR_W) & 1u) { }
        dst[i] = POP_DATA(DIR_W);
    }
}

static inline void write_w(const uint32_t *src, unsigned n) {
    for (unsigned i = 0; i < n; i++) {
        while (PUSH_STATUS(DIR_W) & 1u) { }
        PUSH_DATA(DIR_W) = src[i];
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

static void sha256_block(uint32_t state[8], const uint32_t block[16]) {
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h, t1, t2;

    for (int i = 0; i < 16; i++) w[i] = block[i];
    for (int i = 16; i < 64; i++)
        w[i] = SIG1(w[i-2]) + w[i-7] + SIG0(w[i-15]) + w[i-16];

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (int i = 0; i < 64; i++) {
        t1 = h + EP1(e) + CH(e,f,g) + K[i] + w[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

void main(void) {
    uint32_t state[8];
    uint32_t block[16];
    for (;;) {
        read_w(state, 8);
        read_w(block, 16);
        sha256_block(state, block);
        write_w(state, 8);
    }
}
