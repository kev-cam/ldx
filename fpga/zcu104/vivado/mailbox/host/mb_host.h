/* mb_host.h — ARM-PS driver for the 8x8 mailbox mesh on the ZCU104.
 * Maps the AXI4-Lite slave (mb_array_top) via /dev/mem and gives load / inject /
 * egress / control helpers. Base = the BD-assigned address (0xA0000000 here).
 * Register map mirrors mb_array_top.v. Build with the aarch64 toolchain or natively
 * on the board (see Makefile). Run as root (or with /dev/mem access). */
#ifndef MB_HOST_H
#define MB_HOST_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#ifndef MB_BASE
#define MB_BASE 0xA0000000UL          /* AXI4-Lite slave base (BD address assign) */
#endif
#define MB_SIZE 0x1000

/* register byte offsets (mb_array_top.v) */
enum { R_CTRL=0x00, R_LOADA=0x04, R_LOADD=0x08, R_INGRW0=0x0C,
       R_INGRD1=0x10, R_EGR=0x14, R_STATUS=0x18, R_CYCCNT=0x1C };
/* STATUS bits */
enum { ST_EGR_NE=1, ST_QUIESC=2, ST_INGR_BUSY=4, ST_EGR_FULL=8 };
/* CTRL bits */
enum { CTRL_ARR_RST=1, CTRL_CPU_RST=2 };

typedef struct { volatile uint32_t *r; int fd; } mb_t;

static inline uint32_t mb_rd(mb_t *m, unsigned off)            { return m->r[off>>2]; }
static inline void     mb_wr(mb_t *m, unsigned off, uint32_t v){ m->r[off>>2] = v; }

static int mb_open(mb_t *m) {
    m->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (m->fd < 0) { perror("open /dev/mem"); return -1; }
    m->r = (volatile uint32_t *)mmap(NULL, MB_SIZE, PROT_READ|PROT_WRITE,
                                     MAP_SHARED, m->fd, MB_BASE);
    if (m->r == MAP_FAILED) { perror("mmap"); close(m->fd); return -1; }
    return 0;
}
static void mb_close(mb_t *m) { munmap((void*)m->r, MB_SIZE); close(m->fd); }

/* hold the array + cores in reset, broadcast-load the program to every node's
 * BRAM (low 1024 words), then release. prog = the per-core image (sim .hex). */
static void mb_load_program(mb_t *m, const uint32_t *prog, int nwords) {
    mb_wr(m, R_CTRL, CTRL_ARR_RST | CTRL_CPU_RST);
    usleep(100);
    mb_wr(m, R_LOADA, 0);
    for (int i = 0; i < nwords; i++) mb_wr(m, R_LOADD, prog[i]);   /* LOADA auto-increments */
    mb_wr(m, R_CTRL, 0);                                            /* release */
}

/* read a sim .hex (one 32-bit hex word per line) and load it; returns nwords */
static int mb_load_hex(mb_t *m, const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return -1; }
    static uint32_t prog[4096]; int n = 0; char line[128];
    while (n < 4096 && fgets(line, sizeof line, f))
        if (line[0] && line[0] != '\n') prog[n++] = (uint32_t)strtoul(line, NULL, 16);
    fclose(f);
    mb_load_program(m, prog, n);
    return n;
}

/* inject a 1-word packet (val) to core (y,x). Waits for the ingress FSM to be free. */
static void mb_inject(mb_t *m, int y, int x, uint32_t val) {
    while (mb_rd(m, R_STATUS) & ST_INGR_BUSY) ;
    mb_wr(m, R_INGRW0, ((y & 0xF) << 16) | ((x & 0xF) << 8) | 1u);
    mb_wr(m, R_INGRD1, val);                                        /* fires the send */
}
static inline int      mb_egr_avail(mb_t *m){ return mb_rd(m, R_STATUS) & ST_EGR_NE; }
static inline uint32_t mb_egr_pop(mb_t *m)  { return mb_rd(m, R_EGR); }
static inline uint32_t mb_cyccnt(mb_t *m)   { return mb_rd(m, R_CYCCNT); }
static inline int      mb_quiescent(mb_t *m){ return mb_rd(m, R_STATUS) & ST_QUIESC; }

/* ---- multi-word DUT I/O -------------------------------------------------- *
 * A DUT whose top input is wider than 32 bits (e.g. SHA256's 512-bit block)
 * receives it as n in-order 1-word packets; a wide top output (the 256-bit
 * digest) leaves as n in-order egress payload words. The on-array worker
 * collects/emits in word order (see rtl/mailbox/sha/mb_sha.c). */

/* send the n words of a wide top-input to core (y,x), in order. The worker reads
 * the in-order stream with mb_lowbit(MB_READY), which returns the lowest READY
 * slot — that equals arrival order only while ≤1 packet is in flight (else a
 * freed+reused low slot can jump ahead of an older higher slot). MB_SEND_GAP_US
 * paces injects so the free-running worker drains each word before the next
 * arrives, keeping it 1-in-flight and the stream ordered. */
#ifndef MB_SEND_GAP_US
#define MB_SEND_GAP_US 100
#endif
static void mb_send_words(mb_t *m, int y, int x, const uint32_t *w, int n) {
    for (int i = 0; i < n; i++) { mb_inject(m, y, x, w[i]); if (MB_SEND_GAP_US) usleep(MB_SEND_GAP_US); }
}

/* read n egress payload words (a wide top-output) into buf, in order. Spins on
 * STATUS.egr_ne; the FIFO holds payloads only (headers are dropped in HW). */
static void mb_recv_words(mb_t *m, uint32_t *buf, int n) {
    for (int i = 0; i < n; i++) {
        while (!(mb_rd(m, R_STATUS) & ST_EGR_NE)) ;
        buf[i] = mb_egr_pop(m);
    }
}

/* one SHA256 block: feed 16 words (w[0]=block[31:0]…w[15]=block[511:480]) to
 * core (y,x) and read back the 8 digest words (h0..h7, MSB first). Targets the
 * single-block worker (rtl/mailbox/sha/mb_sha.c). */
static void mb_sha256_block(mb_t *m, int y, int x,
                            const uint32_t blk[16], uint32_t digest[8]) {
    mb_send_words(m, y, x, blk, 16);
    mb_recv_words(m, digest, 8);
}

/* SHA-256 pad `msg` into big-endian 512-bit block words. `blocks` is a caller
 * buffer of at least ((len+8)/64 + 1)*16 words; returns the block count. */
static int mb_sha256_pad(const uint8_t *msg, uint32_t len, uint32_t *blocks) {
    int nb = (int)((len + 8) / 64 + 1);
    for (int i = 0; i < nb*16; i++) blocks[i] = 0;
    for (uint32_t i = 0; i < len; i++)
        blocks[i>>2] |= (uint32_t)msg[i] << (24 - 8*(i & 3));   /* big-endian word */
    blocks[len>>2] |= (uint32_t)0x80u << (24 - 8*(len & 3));    /* 0x80 terminator */
    uint64_t bl = (uint64_t)len * 8u;                          /* bit length, last 64b */
    blocks[nb*16 - 2] = (uint32_t)(bl >> 32);
    blocks[nb*16 - 1] = (uint32_t)(bl & 0xffffffffu);
    return nb;
}

/* multi-block SHA256: stream the block count then nblk*16 block words to core
 * (y,x), read back the digest. Targets the multi-block worker (mb_shamb.c). */
static void mb_sha256(mb_t *m, int y, int x,
                      const uint32_t *blocks, int nblk, uint32_t digest[8]) {
    mb_inject(m, y, x, (uint32_t)nblk);
    mb_send_words(m, y, x, blocks, nblk*16);
    mb_recv_words(m, digest, 8);
}

/* hash an arbitrary byte message on the array (pad + stream + read digest).
 * `blocks` is a caller scratch buffer of ((len+8)/64 + 1)*16 words. */
static void mb_sha256_msg(mb_t *m, int y, int x, const uint8_t *msg, uint32_t len,
                          uint32_t *blocks, uint32_t digest[8]) {
    int nb = mb_sha256_pad(msg, len, blocks);
    mb_sha256(m, y, x, blocks, nb, digest);
}

#endif /* MB_HOST_H */
