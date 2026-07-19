/* mb_bench.c — cycles/eval probe: emit a start marker, run N sm_evals, emit a
 * done marker. The TB counts clk cycles between the two egress markers. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "stage_sm.c"
#define NEV 1000u
void main(void){
    state_t S; inputs_t in; outputs_t o;
    sm_reset(&S); S._s=1u;
    MB_CORE_BUSY=0u;
    mb_display(0u, 0xAAAA0000u);                 /* start marker */
    for (uint32_t i=0;i<NEV;i++) sm_eval(&S,&in,&o);
    mb_display(0u, 0xBBBB0000u | ((uint32_t)o._s & 0xFFFFu));  /* done marker */
    for(;;){}
}
