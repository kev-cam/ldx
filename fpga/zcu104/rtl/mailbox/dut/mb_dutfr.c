/* mb_dutfr.c — FREE-RUNNING DUT: each core runs the FSM in a tight loop with NO
 * barrier (independent workload needs no global lockstep). Tile 0 emits its
 * iteration count every 2^16 evals so the ARM can measure the per-core eval rate.
 * Compare to mb_dut (barrier lockstep) to see the barrier tax. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "stage_sm.c"
void main(void){
    uint32_t id=(mb_my_y()<<4)|mb_my_x();
    state_t S; inputs_t in; outputs_t o;
    sm_reset(&S); S._s=id+1u;
    MB_CORE_BUSY=0u;                 /* clear reset-busy, then free-run (no barrier) */
    uint32_t n=0u;
    for(;;){
        sm_eval(&S,&in,&o);
        n++;
        if(id==0u && (n & 0xFFFFu)==0u) mb_display(0u, n);   /* tile 0: emit count */
    }
}
