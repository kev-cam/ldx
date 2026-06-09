/* mb_diag.c — bounded, verbose SHA bring-up probe (no infinite spins). */
#include "mb_host.h"
#include <string.h>
static const uint32_t ABC_BLK[16] = {0x61626380,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0x18};

static void st(mb_t *m, const char *tag){
    printf("%-14s STATUS=0x%08x CYCCNT=0x%08x\n", tag, mb_rd(m,R_STATUS), mb_rd(m,R_CYCCNT));
}
int main(int argc, char **argv){
    const char *hex = argc>1 ? argv[1] : "mb_sha.hex";
    mb_t m; if (mb_open(&m)) return 1;
    st(&m, "raw@open");

    /* drain any stale egress left in the FIFO from a prior run (FIFO survives arr_reset) */
    int drained = 0;
    while ((mb_rd(&m,R_STATUS)&ST_EGR_NE) && drained < 4096) { (void)mb_egr_pop(&m); drained++; }
    printf("drained %d stale egress words; STATUS=0x%x\n", drained, mb_rd(&m,R_STATUS));

    int n = mb_load_hex(&m, hex);
    printf("loaded %s: %d words\n", hex, n);
    usleep(5000);
    st(&m, "after-load");

    /* inject the 16 abc block words; bound the ingr-busy wait per word */
    for (int i=0;i<16;i++){
        int t=0; while ((mb_rd(&m,R_STATUS)&ST_INGR_BUSY) && ++t<1000000) ;
        if (t>=1000000){ printf("ingr-busy STUCK before word %d\n", i); break; }
        mb_wr(&m, R_INGRW0, (0<<16)|(0<<8)|1u);
        mb_wr(&m, R_INGRD1, ABC_BLK[i]);
    }
    st(&m, "after-inject");

    /* bounded egress drain */
    uint32_t got[16]; int ng=0;
    for (long spin=0; spin<20000000L && ng<8; spin++){
        if (mb_rd(&m,R_STATUS)&ST_EGR_NE){ got[ng++]=mb_egr_pop(&m); }
    }
    printf("egress words: %d\n", ng);
    for (int i=0;i<ng;i++) printf("  egr[%d]=%08x\n", i, got[i]);
    st(&m, "final");
    mb_close(&m);
    return 0;
}
