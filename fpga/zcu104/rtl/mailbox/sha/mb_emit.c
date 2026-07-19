#include "mailbox.h"
void main(void){
    uint32_t id=(mb_my_y()<<4)|mb_my_x();
    MB_CORE_BUSY=0u;                 /* clear reset-busy, then free-run */
    uint32_t n=0u;
    for(;;){
        if(id==0u){ mb_display(0u, 0xE0000000u | (n & 0xFFFFFFu)); n++; }
        for(volatile int d=0; d<2000; d++){}   /* throttle */
    }
}
