/* mb_pipe.c — a compute pipeline distributed across row 0 of the mesh. Each tile
 * runs the accel-C stage (dout<=din+1) and forwards to its E (adjacent) neighbor.
 * Tile (0,0) feeds din=cnt*10; after PIPE_LEN stages the output is cnt*10+PIPE_LEN,
 * so every output is ==PIPE_LEN (mod 10) and rises by 10. Off-row tiles just engage
 * the barrier. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "stage_sm.c"          /* sm_eval: state_t{_dout}, inputs_t{_din}, outputs_t{_dout} */
#ifndef PIPE_LEN
#define PIPE_LEN 4
#endif
volatile uint32_t *const RESULT = (uint32_t *)0x80000F00u;
static uint32_t recvw(void){
    while (MB_READY==0u){}
    uint32_t s=mb_lowbit(MB_READY); uint32_t v=MB_SLOT(s,1); MB_DONE=s; return v;
}
void main(void){
    uint32_t y=mb_my_y(), x=mb_my_x();
    if (y==0u && x<(uint32_t)PIPE_LEN){           /* pipeline stage */
        state_t *S=(state_t *)0x80000F20u;
        inputs_t in; outputs_t o;
        sm_reset(S);
        uint32_t cnt=0u, n=0u;
        for(;;){
            MB_CORE_BUSY=1u; uint32_t c0=MB_CYCLE_CNT;
            if (x==0u){ in._din=(cnt<<3)+(cnt<<1); cnt++; }   /* generate cnt*10 */
            else        in._din=recvw();                       /* receive from W neighbor */
            sm_eval(S,&in,&o);
            if (x==(uint32_t)(PIPE_LEN-1)){ if(n<14u) RESULT[2u+n]=(uint32_t)o._dout; n++; }
            else mb_post1(0u, x+1u, (uint32_t)o._dout);        /* -> E neighbor */
            MB_CORE_BUSY=0u; while(MB_CYCLE_CNT==c0){}
        }
    } else {                                       /* off-pipeline: engage the barrier */
        for(;;){ MB_CORE_BUSY=1u; uint32_t c0=MB_CYCLE_CNT; MB_CORE_BUSY=0u; while(MB_CYCLE_CNT==c0){} }
    }
}
