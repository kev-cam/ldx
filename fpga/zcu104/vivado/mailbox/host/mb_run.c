/* mb_run.c — load a program onto the 8x8 mailbox array and run it from the ARM.
 *
 *   mb_run <prog.hex> [--drive N] [--stream SECS]
 *
 *  --drive N    ARM is the testbench: inject x = 0..N-1 to core (0,0) and read one
 *               egress output per input (lock-step; ARM/AXI-bound — for CORRECTNESS).
 *  --stream S   array runs autonomously for S seconds; ARM drains egress and samples
 *               CYCCNT -> the array's simulated-cycle rate (THROUGHPUT/speedup).
 *  default: --stream 2
 *
 * The .hex is the same per-core image the Verilator sims load (e.g. m3c/mb_raccel.hex,
 * mesh/mb_relay.hex, pipe/mb_pipe.hex). Build: see Makefile. Run as root.
 */
#include "mb_host.h"
#include <time.h>

static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
                         return t.tv_sec + t.tv_nsec*1e-9; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr,"usage: %s <prog.hex> [--drive N | --stream SECS]\n",argv[0]); return 1; }
    const char *hex = argv[1];
    int drive_n = 0; double stream_s = 2.0;
    for (int i=2;i<argc;i++) {
        if (!strcmp(argv[i],"--drive")  && i+1<argc) drive_n  = atoi(argv[++i]);
        else if (!strcmp(argv[i],"--stream") && i+1<argc) stream_s = atof(argv[++i]);
    }

    mb_t m;
    if (mb_open(&m)) return 1;
    int nw = mb_load_hex(&m, hex);
    if (nw < 0) { mb_close(&m); return 1; }
    printf("loaded %s (%d words) -> 8x8 array @ 0x%08lX, released\n", hex, nw, (unsigned long)MB_BASE);
    while (mb_egr_avail(&m)) mb_egr_pop(&m);                 /* flush stale egress */

    if (drive_n > 0) {
        /* ---- correctness: ARM drives x, reads result (lock-step) ---- */
        printf("--drive %d : inject x=0..%d to (0,0), read egress\n", drive_n, drive_n-1);
        double t0 = now();
        for (int x=0; x<drive_n; x++) {
            mb_inject(&m, 0, 0, (uint32_t)x);
            int spins=0; while (!mb_egr_avail(&m) && spins++<10000000) ;
            uint32_t out = mb_egr_avail(&m) ? mb_egr_pop(&m) : 0xDEAD;
            if (x < 16 || x == drive_n-1) printf("  in=%u  out=%u\n", x, out);
        }
        double dt = now()-t0;
        printf("drove %d inputs in %.3f s = %.0f inputs/s (ARM/AXI-bound)\n",
               drive_n, dt, drive_n/dt);
    } else {
        /* ---- throughput: array free-runs, measure simulated cycles/s ---- */
        printf("--stream %.1f s : array autonomous, draining egress\n", stream_s);
        uint32_t c0 = mb_cyccnt(&m); double t0 = now();
        long outs = 0; uint32_t first=0, last=0;
        while (now()-t0 < stream_s) {
            for (int k=0;k<256 && mb_egr_avail(&m);k++){ uint32_t v=mb_egr_pop(&m); if(!outs)first=v; last=v; outs++; }
        }
        double dt = now()-t0; uint32_t c1 = mb_cyccnt(&m);
        uint32_t cyc = c1 - c0;
        printf("array advanced %u simulated cycles in %.3f s = %.3f Mcycles/s\n",
               cyc, dt, cyc/dt/1e6);
        printf("egress outputs drained: %ld  (first=%u last=%u)\n", outs, first, last);
        printf("compare to your software sim's cycles/s for the speedup.\n");
    }
    mb_close(&m);
    return 0;
}
