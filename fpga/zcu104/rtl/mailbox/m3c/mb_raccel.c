/* mb_raccel.c — RTL accel demo: the consumer is a 1-core DUT. Its top-input x is
 * driven by the ARM over host ingress; its top-output result goes back to the ARM
 * over egress. The testbench (stimulus + checking) lives on the ARM, not here. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "consumer_sm.c"        /* the DUT: sm_eval, state_t{_result}, inputs_t{_x}, outputs_t{_result} */

static uint32_t recv_word(void){
    while (MB_READY==0u){}
    uint32_t s=mb_lowbit(MB_READY); uint32_t v=MB_SLOT(s,1); MB_DONE=s; return v;
}
void main(void){
    state_t *S = (state_t *)0x80000F20u;     /* DUT registers in BRAM */
    inputs_t in; outputs_t o;
    sm_reset(S);
    for(;;){
        MB_CORE_BUSY=1u; uint32_t c0=MB_CYCLE_CNT;
        in._x = recv_word();                 /* DUT top-input x  <- ARM (ingress) */
        sm_eval(S, &in, &o);
        mb_display(0u, (uint32_t)o._result); /* DUT top-output result -> ARM (egress) */
        MB_CORE_BUSY=0u; while(MB_CYCLE_CNT==c0){}
    }
}
