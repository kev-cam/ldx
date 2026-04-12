/* sha256.c — Bare-metal SHA-256 benchmark for ARV SoC.
 *
 * Computes SHA-256 of a short test message and writes the first 4 words
 * of the hash to the SoC's IO_RESULT registers, then signals IO_DONE.
 *
 * Build two versions:
 *   make sha256_sw.bin   — pure software (all rotates in C)
 *   make sha256_cfu.bin  — CFU-accelerated (rotates via CUSTOM_0 funct3=5)
 *
 * The host measures wall time from reset-release to done-flag.
 */
#include <stdint.h>

/* ---- SoC I/O registers ---- */
#define IO_RESULT0  (*(volatile uint32_t*)0xF0000000)
#define IO_DONE     (*(volatile uint32_t*)0xF0000004)
#define IO_RESULT1  (*(volatile uint32_t*)0xF0000008)
#define IO_RESULT2  (*(volatile uint32_t*)0xF000000C)
#define IO_RESULT3  (*(volatile uint32_t*)0xF0000010)

/* ---- Rotate right ---- */
#ifdef USE_CFU
/* CUSTOM_0 rd, rs1, rs2, funct3=5 → rotr(rs1, rs2) */
static inline uint32_t rotr(uint32_t x, uint32_t n) {
    uint32_t result;
    __asm__ volatile(
        ".insn r 0x0b, 5, 0, %0, %1, %2"
        : "=r"(result) : "r"(x), "r"(n));
    return result;
}
#else
static inline uint32_t rotr(uint32_t x, uint32_t n) {
    return (x >> n) | (x << (32 - n));
}
#endif

/* ---- SHA-256 core ---- */
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define CH(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x)     (rotr(x, 2) ^ rotr(x,13) ^ rotr(x,22))
#define EP1(x)     (rotr(x, 6) ^ rotr(x,11) ^ rotr(x,25))
#define SIG0(x)    (rotr(x, 7) ^ rotr(x,18) ^ ((x) >> 3))
#define SIG1(x)    (rotr(x,17) ^ rotr(x,19) ^ ((x) >> 10))

static void sha256_block(uint32_t state[8], const uint32_t block[16]) {
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h;
    uint32_t t1, t2;
    int i;

    for (i = 0; i < 16; i++) w[i] = block[i];
    for (i = 16; i < 64; i++)
        w[i] = SIG1(w[i-2]) + w[i-7] + SIG0(w[i-15]) + w[i-16];

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (i = 0; i < 64; i++) {
        t1 = h + EP1(e) + CH(e,f,g) + K[i] + w[i];
        t2 = EP0(a) + MAJ(a,b,c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

/* ---- Entry point (bare-metal, no stdlib) ---- */
void __attribute__((naked)) _start(void) {
    __asm__ volatile("li sp, 0x80001000");
    __asm__ volatile("j _main");
}

void __attribute__((noinline)) _main(void) {
    /* SHA-256 of "abc" (3 bytes).
     * Pre-padded 512-bit block: 61626380 00000000 ... 00000018
     * Expected hash: ba7816bf 8f01cfea 414140de 5dae2223
     *                b00361a3 96177a9c b410ff61 f20015ad
     */
    uint32_t block[16] = {
        0x61626380, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x00000000, 0x00000018
    };

    uint32_t state[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };

    /* Run N_ITERS iterations to get a measurable time */
    for (int iter = 0; iter < N_ITERS; iter++) {
        state[0] = 0x6a09e667; state[1] = 0xbb67ae85;
        state[2] = 0x3c6ef372; state[3] = 0xa54ff53a;
        state[4] = 0x510e527f; state[5] = 0x9b05688c;
        state[6] = 0x1f83d9ab; state[7] = 0x5be0cd19;
        sha256_block(state, block);
    }

    IO_RESULT0 = state[0];  /* expect 0xba7816bf */
    IO_RESULT1 = state[1];  /* expect 0x8f01cfea */
    IO_RESULT2 = state[2];  /* expect 0x414140de */
    IO_RESULT3 = state[3];  /* expect 0x5dae2223 */
    IO_DONE = 1;
    while(1);
}
