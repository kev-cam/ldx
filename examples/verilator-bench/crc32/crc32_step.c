// crc32_step.c — one byte of IEEE-802.3 CRC-32. Flat for c2v.
#include <stdint.h>

uint32_t crc32_step(uint32_t state, uint32_t byte_in) {
    uint32_t s0 = state ^ byte_in;

    uint32_t b0 = s0 & 1;
    uint32_t m0 = 0 - b0;
    uint32_t s1 = (s0 >> 1) ^ (m0 & 0xEDB88320);

    uint32_t b1 = s1 & 1;
    uint32_t m1 = 0 - b1;
    uint32_t s2 = (s1 >> 1) ^ (m1 & 0xEDB88320);

    uint32_t b2 = s2 & 1;
    uint32_t m2 = 0 - b2;
    uint32_t s3 = (s2 >> 1) ^ (m2 & 0xEDB88320);

    uint32_t b3 = s3 & 1;
    uint32_t m3 = 0 - b3;
    uint32_t s4 = (s3 >> 1) ^ (m3 & 0xEDB88320);

    uint32_t b4 = s4 & 1;
    uint32_t m4 = 0 - b4;
    uint32_t s5 = (s4 >> 1) ^ (m4 & 0xEDB88320);

    uint32_t b5 = s5 & 1;
    uint32_t m5 = 0 - b5;
    uint32_t s6 = (s5 >> 1) ^ (m5 & 0xEDB88320);

    uint32_t b6 = s6 & 1;
    uint32_t m6 = 0 - b6;
    uint32_t s7 = (s6 >> 1) ^ (m6 & 0xEDB88320);

    uint32_t b7 = s7 & 1;
    uint32_t m7 = 0 - b7;
    uint32_t s8 = (s7 >> 1) ^ (m7 & 0xEDB88320);

    return s8;
}
