/* mb_sha.c — SHA256 DUT on one array core. Multi-word I/O: the 512-bit block
 * arrives as 16 in-order 1-word ingress packets (w[0]=block[31:0] first, …,
 * w[15] last), and the 256-bit digest leaves as 8 in-order egress words (h0..h7,
 * MSB first). Reads the payload at MB_SLOT(slot,1) — word0 is routing metadata.
 *
 * FREE-RUNNING (no barrier): SHA is a single-core compute accelerator with no
 * inter-core communication, so it does NOT use the cycle barrier. This is also
 * REQUIRED on a multi-core array: the program is broadcast to every core, and the
 * idle cores (no ingress) would otherwise hold the barrier (busy, or never
 * engaging) so cycle_advance never fires. The NIF delivers ingress and drains
 * egress independent of the barrier, so the worker just collects/computes/emits. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "sha_sm.c"                 /* wide-signal accel-C: block[16]/digest[8] */
static state_t S;                   /* SHA state (K ROM + w + a..h) in BSS */

static uint32_t recv_word(void){
    while (MB_READY==0u){}
    uint32_t s=mb_lowbit(MB_READY); uint32_t v=MB_SLOT(s,1); MB_DONE=s; return v;
}
void main(void){
    inputs_t in; outputs_t o;
    for (int i=0;i<16;i++) in._block[i]=0u;
    in._start=0u;
    sm_reset(&S);
    MB_CORE_BUSY=0u;                /* clear the reset-busy once; then free-run */
    for(;;){
        for (int i=0;i<16;i++) in._block[i]=recv_word();   /* collect the block */
        in._start=1u; sm_eval(&S,&in,&o); in._start=0u;    /* pulse start */
        uint32_t g=0u;
        while (!o._done && g<512u){ sm_eval(&S,&in,&o); g++; }   /* run to done */
        for (int w=7; w>=0; w--)                           /* emit digest h0..h7 (MSB first) */
            mb_display(0u, (uint32_t)o._digest[w]);
    }
}
