/* mb_dut.c — self-driving benchmark DUT: EVERY tile runs the xorshift32 FSM
 * (stage_sm.c) autonomously, in lockstep via the barrier. No ARM input. Tile (0,0)
 * — the egress-reachable tile — emits its state every EGR_PERIOD cycles, so the
 * array free-runs at full rate and the ARM samples egress without backpressure.
 * 64 FSMs in parallel = the workload a host sim would run serially. */
#include "mailbox.h"
#define SM_NO_MAIN 1
#include "stage_sm.c"          /* xorshift32: state_t{_s}, outputs_t{_s}, inputs_t{_dummy} */
#ifndef EGR_PERIOD
#define EGR_PERIOD 64u         /* power of 2 */
#endif
void main(void){
    uint32_t id = (mb_my_y()<<4) | mb_my_x();
    state_t S; inputs_t in; outputs_t o;
    sm_reset(&S); S._s = id + 1u;   /* seed (sync-reset value not captured by gen_sm) */
    uint32_t n=0u;
    for(;;){
        MB_CORE_BUSY=1u; uint32_t c0=MB_CYCLE_CNT;
        sm_eval(&S, &in, &o);                 /* the per-cycle compute */
        n++;
        if (id==0u && (n & (EGR_PERIOD-1u))==0u) mb_display(0u, (uint32_t)o._s);
        MB_CORE_BUSY=0u; while(MB_CYCLE_CNT==c0){}
    }
}
