/* mb_shamb.c — MULTI-BLOCK SHA256 DUT on one array core. A message of N 512-bit
 * blocks is streamed in as: one count word (N), then N*16 in-order block words.
 * The DUT (Sha256mb, gen_statemachine accel-C) hashes block 0 with cont=0 (IV)
 * and blocks 1..N-1 with cont=1 (chain from the running hash kept in state_t),
 * then the 8 digest words (h0..h7, MSB first) leave off-array. Same barrier
 * discipline + payload-at-MB_SLOT(slot,1) convention as mb_sha.c. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "shamb_sm.c"               /* wide-signal accel-C: block[16]/digest[8]/cont */
static state_t S;

static uint32_t recv_word(void){
    while (MB_READY==0u){}
    uint32_t s=mb_lowbit(MB_READY); uint32_t v=MB_SLOT(s,1); MB_DONE=s; return v;
}
void main(void){
    inputs_t in; outputs_t o;
    for (int i=0;i<16;i++) in._block[i]=0u;
    in._start=0u; in._cont=0u;
    sm_reset(&S);
    for(;;){
        uint32_t c0;
        MB_CORE_BUSY=1u; c0=MB_CYCLE_CNT;            /* word 0 of a job = block count */
        uint32_t nblk=recv_word();
        MB_CORE_BUSY=0u; while (MB_CYCLE_CNT==c0){}
        for (uint32_t b=0;b<nblk;b++){
            for (int i=0;i<16;i++){                   /* one block, one word per barrier cycle */
                MB_CORE_BUSY=1u; c0=MB_CYCLE_CNT;
                in._block[i]=recv_word();
                MB_CORE_BUSY=0u; while (MB_CYCLE_CNT==c0){}
            }
            in._cont = (b>0u)?1u:0u;                  /* first block IV, rest chain */
            in._start=1u; sm_eval(&S,&in,&o); in._start=0u;
            uint32_t g=0u;
            while (!o._done && g<512u){ sm_eval(&S,&in,&o); g++; }
        }
        for (int w=7; w>=0; w--){                     /* emit digest h0..h7 (MSB first) */
            MB_CORE_BUSY=1u; c0=MB_CYCLE_CNT;
            mb_display(0u, (uint32_t)o._digest[w]);
            MB_CORE_BUSY=0u; while (MB_CYCLE_CNT==c0){}
        }
    }
}
