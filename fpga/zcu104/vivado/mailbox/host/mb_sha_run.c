/* mb_sha_run.c — run SHA256 on the mailbox array from the ARM (the testbench).
 *   sudo ./mb_sha_run <prog.hex> single        # single-block worker (mb_sha.hex):  SHA256("abc")
 *   sudo ./mb_sha_run <prog.hex> multi [msg]    # multi-block worker (mb_shamb.hex): SHA256(msg)
 * Loads the per-core program, drives the DUT top-input (block words) over host
 * ingress, reads the digest back over egress, and checks the known vectors. */
#include "mb_host.h"
#include <string.h>

static const uint32_t ABC_BLK[16] = {0x61626380,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x18};
static const uint32_t ABC_EXP[8]  = {0xba7816bf,0x8f01cfea,0x414140de,0x5dae2223,
                                     0xb00361a3,0x96177a9c,0xb410ff61,0xf20015ad};
/* SHA256("abcdbcde…nopq", 56B) — the classic 2-block FIPS vector */
static const char    *FIPS_MSG = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
static const uint32_t FIPS_EXP[8] = {0x248d6a61,0xd20638b8,0xe5c02693,0x0c3e6039,
                                     0xa33ce459,0x64ff2167,0xf6ecedd4,0x19db06c1};

static int show(const char *name, const uint32_t *d, const uint32_t *e) {
    int bad = 0;
    printf("%-22s", name);
    for (int i = 0; i < 8; i++) { printf(" %08x", d[i]); if (e && d[i] != e[i]) bad++; }
    printf(e ? (bad ? "   FAIL\n" : "   OK\n") : "\n");
    return bad;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <prog.hex> single|multi [msg]\n", argv[0]); return 2; }
    mb_t m;
    if (mb_open(&m)) return 1;
    int n = mb_load_hex(&m, argv[1]);
    if (n < 0) { mb_close(&m); return 1; }
    printf("loaded %s: %d words; STATUS=0x%x\n", argv[1], n, mb_rd(&m, R_STATUS));
    usleep(5000);                          /* let core (0,0) boot */

    uint32_t d[8]; int bad = 0;
    if (!strcmp(argv[2], "single")) {
        mb_sha256_block(&m, 0, 0, ABC_BLK, d);
        bad += show("SHA256(\"abc\")", d, ABC_EXP);
    } else {
        const char *msg = (argc > 3) ? argv[3] : FIPS_MSG;
        const uint32_t *exp = (argc > 3) ? NULL : FIPS_EXP;
        static uint32_t blocks[64*16];     /* up to 64 blocks of scratch */
        mb_sha256_msg(&m, 0, 0, (const uint8_t*)msg, (uint32_t)strlen(msg), blocks, d);
        char label[64]; snprintf(label, sizeof label, "SHA256(%uB)", (unsigned)strlen(msg));
        bad += show(label, d, exp);
    }
    mb_close(&m);
    printf(bad ? "HW-SHA FAIL\n" : "HW-SHA PASS\n");
    return bad ? 1 : 0;
}
