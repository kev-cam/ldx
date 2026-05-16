// ldx_daemon.c — A53 userspace daemon for milestone-1 ldx softcore.
//
// 1. mmap the AXI4-Lite slave at LDX_BASE (default 0xA0000000, 8 KB).
// 2. Verify MAGIC.
// 3. Load BRAM with bare-metal RV32I firmware (hello.bin).
// 4. Release CPU.
// 5. Poll mailbox, relay each posted byte to stdout, reply 0.
//
// Build: aarch64-linux-gnu-gcc -static -O2 -o ldx_daemon ldx_daemon.c
// Run on ZCU104:  sudo ./ldx_daemon hello.bin

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LDX_BASE    0xA0000000UL
#define LDX_SIZE    0x2000U

#define OFF_BRAM    0x0000
#define OFF_CTRL    0x1F00
#define OFF_MBOX    0x1F04
#define OFF_STATUS  0x1F08
#define OFF_MAGIC   0x1F80

#define MAGIC_VAL   0x4C445833u   // "LDX3"

static volatile uint32_t *regs;

static inline uint32_t rd(unsigned off) { return regs[off >> 2]; }
static inline void     wr(unsigned off, uint32_t v) { regs[off >> 2] = v; }

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <firmware.bin>\n", argv[0]);
        return 1;
    }

    int fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem < 0) { perror("/dev/mem"); return 1; }

    regs = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd_mem, LDX_BASE);
    if (regs == MAP_FAILED) { perror("mmap"); return 1; }

    uint32_t magic = rd(OFF_MAGIC);
    if (magic != MAGIC_VAL) {
        fprintf(stderr, "bad magic: 0x%08x (want 0x%08x)\n", magic, MAGIC_VAL);
        return 1;
    }
    fprintf(stderr, "[ldx] magic OK\n");

    // Hold CPU in reset (likely already held by reset, but be explicit)
    wr(OFF_CTRL, 1);

    // Load firmware into BRAM (32-bit aligned, padded with zeros)
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz > 4096) {
        fprintf(stderr, "firmware too large: %ld bytes (max 4096)\n", sz);
        return 1;
    }
    uint8_t buf[4096] = {0};
    if (fread(buf, 1, sz, f) != (size_t)sz) { perror("fread"); return 1; }
    fclose(f);

    for (long i = 0; i < (sz + 3) / 4; i++) {
        uint32_t w = (uint32_t)buf[i*4+0]
                   | ((uint32_t)buf[i*4+1] << 8)
                   | ((uint32_t)buf[i*4+2] << 16)
                   | ((uint32_t)buf[i*4+3] << 24);
        wr(OFF_BRAM + i*4, w);
    }
    fprintf(stderr, "[ldx] loaded %ld bytes; releasing CPU\n", sz);

    // Release CPU
    wr(OFF_CTRL, 0);

    // PS daemon loop
    fprintf(stderr, "[ldx] ===== softcore output =====\n");
    for (;;) {
        if (rd(OFF_STATUS) & 1u) {
            uint32_t v = rd(OFF_MBOX);
            uint8_t c = v & 0xff;
            putchar(c);
            fflush(stdout);
            wr(OFF_MBOX, 0);     // reply, clears pending
        }
    }
    return 0;
}
