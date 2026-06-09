/* mb_sha.c — SHA256 DUT on one array core. Multi-word I/O: the 512-bit block
 * arrives as 16 in-order 1-word ingress packets (w[0]=block[31:0] first, …,
 * w[15] last), and the 256-bit digest leaves as 8 in-order egress words (h0..h7,
 * MSB first). The worker participates in the barrier (MB_CORE_BUSY + MB_CYCLE_CNT)
 * exactly like the proven raccel DUT, so ingress/egress stay in lockstep with the
 * ARM testbench. Reads the payload at MB_SLOT(slot,1) — word0 is routing metadata. */
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
    for(;;){
        uint32_t c0;
        for (int i=0;i<16;i++){               /* collect block, one word per barrier cycle */
            MB_CORE_BUSY=1u; c0=MB_CYCLE_CNT;
            in._block[i]=recv_word();
            MB_CORE_BUSY=0u; while (MB_CYCLE_CNT==c0){}
        }
        in._start=1u; sm_eval(&S,&in,&o); in._start=0u;   /* pulse start */
        uint32_t g=0u;
        while (!o._done && g<512u){ sm_eval(&S,&in,&o); g++; }   /* run to done */
        for (int w=7; w>=0; w--){              /* emit digest h0..h7, one per barrier cycle */
            MB_CORE_BUSY=1u; c0=MB_CYCLE_CNT;
            mb_display(0u, (uint32_t)o._digest[w]);
            MB_CORE_BUSY=0u; while (MB_CYCLE_CNT==c0){}
        }
    }
}
