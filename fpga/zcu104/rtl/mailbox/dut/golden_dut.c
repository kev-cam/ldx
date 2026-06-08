#define SM_NO_MAIN 1
#include "stage_sm.c"
#include <stdio.h>
#ifndef EGR_PERIOD
#define EGR_PERIOD 64
#endif
int main(void){
    state_t s; inputs_t in={0}; outputs_t o; sm_reset(&s); s._s = 1; /* tile 0 seed */
    unsigned n=0, em=0;
    while (em < 12){ sm_eval(&s,&in,&o); n++;
        if ((n & (EGR_PERIOD-1))==0){ printf("%u\n",(unsigned)o._s); em++; } }
    return 0;
}
