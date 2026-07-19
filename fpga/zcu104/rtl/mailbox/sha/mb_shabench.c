/* mb_shabench.c — SHA256 compute throughput: hash the "abc" block NBLK times
 * back-to-back (no mailbox I/O between), so the TB measures pure compute cyc/block. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "sha_sm.c"
#ifndef NBLK
#define NBLK 100u
#endif
static state_t S;
void main(void){
    inputs_t in; outputs_t o; int i; uint32_t h,g;
    for(i=0;i<16;i++) in._block[i]=0u;
    in._block[0]=0x61626380u; in._block[15]=0x18u; in._start=0u;
    sm_reset(&S); MB_CORE_BUSY=0u;
    mb_display(0u, 0xAAAA0000u);                              /* start */
    for(h=0;h<NBLK;h++){
        in._start=1u; sm_eval(&S,&in,&o); in._start=0u;
        g=0u; while(!o._done && g<256u){ sm_eval(&S,&in,&o); g++; }
    }
    mb_display(0u, 0xBBBB0000u | (o._digest[7]&0xFFFFu));     /* done + digest[7] (abc -> ba7816bf) */
    for(;;){}
}
