/* mb_bank.c — banked vs naive double-buffer microbenchmark. Cycle-based update of
 * an N-word registered signal state (stencil: each word reads its neighbor, so
 * the whole state is double-buffered every simulated cycle).
 *   -DBANKED=0 : naive  — compute nxt[] from cur[], then memcpy nxt->cur each cycle
 *   -DBANKED=1 : banked — write the INACTIVE bank, flip parity. No copy.
 * Same computation either way; the TB counts clk cycles over NCYC -> cyc/cycle. */
#include "mailbox.h"
#ifndef N
#define N 256
#endif
#ifndef NCYC
#define NCYC 200u
#endif
#ifndef BANKED
#define BANKED 0
#endif
#if BANKED
static uint32_t bank[2][N];
#else
static uint32_t cur[N], nxt[N];
#endif
void main(void){
    MB_CORE_BUSY=0u;
    int i; uint32_t c;
#if BANKED
    for(i=0;i<N;i++){ bank[0][i]=(uint32_t)(i+1); bank[1][i]=0u; }
    uint32_t p=0u;
#else
    for(i=0;i<N;i++){ cur[i]=(uint32_t)(i+1); }
#endif
    mb_display(0u, 0xAAAA0000u);                          /* start marker */
    for(c=0;c<NCYC;c++){
#if BANKED
        uint32_t *r=bank[p], *w=bank[p^1u];
        for(i=0;i<N;i++) w[i] = r[i] + r[(i+1)&(N-1)] + 1u;    /* stencil into inactive bank */
        p ^= 1u;                                          /* swap by addressing — no copy */
#else
        for(i=0;i<N;i++) nxt[i] = cur[i] + cur[(i+1)&(N-1)] + 1u;
        for(i=0;i<N;i++) cur[i] = nxt[i];                 /* naive copy-back */
#endif
    }
#if BANKED
    uint32_t sum=0u; for(i=0;i<N;i++) sum+=bank[p][i]; mb_display(0u, 0xBBBB0000u | (sum&0xFFFFu));   /* done + result for correctness */
#else
    uint32_t sum=0u; for(i=0;i<N;i++) sum+=cur[i]; mb_display(0u, 0xBBBB0000u | (sum&0xFFFFu));
#endif
    for(;;){}
}
