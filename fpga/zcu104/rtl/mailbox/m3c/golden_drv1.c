#define SM_NO_MAIN 1
#include "top_sm.c"
#include <stdio.h>
int main(void){
    state_t s; inputs_t in = {0}; outputs_t o;
    sm_reset(&s);
    for (int i=0; i<12; i++){ sm_eval(&s, &in, &o); printf("%u\n", (unsigned)o._result); }
    return 0;
}
