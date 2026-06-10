/* mb_shatime.c — time a self-timing worker on the board: load it, wait for the
 * 0xAAAA start marker, then time to the 0xBBBB done marker. Reports cyc/block. */
#include "mb_host.h"
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }
int main(int argc, char **argv){
    if (argc < 2){ fprintf(stderr,"usage: %s <prog.hex> [nblocks]\n",argv[0]); return 1; }
    long nb = (argc>2)? atol(argv[2]) : 100;
    mb_t m; if (mb_open(&m)) return 1;
    mb_load_hex(&m, argv[1]);                 /* arr_reset clears the FIFO on this bitstream */
    double t0=0, t1=0; uint32_t v=0, last=0; int started=0;
    for (long s=0; s<2000000000L && !t1; s++){
        if (mb_egr_avail(&m)){
            v = mb_egr_pop(&m); last=v;
            if ((v>>16)==0xAAAAu && !started){ t0=now(); started=1; }
            else if ((v>>16)==0xBBBBu && started){ t1=now(); }
        }
    }
    if (!t1){ printf("no done marker seen\n"); return 1; }
    double dt = t1 - t0;
    printf("%ld blocks in %.6f s : %.0f cyc/block @200MHz, %.1f Kblocks/s/core, result&ffff=%04x\n",
           nb, dt, dt*200e6/nb, nb/dt/1e3, last & 0xFFFFu);
    mb_close(&m);
    return 0;
}
