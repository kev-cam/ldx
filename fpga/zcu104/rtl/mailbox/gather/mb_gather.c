/* mb_gather.c — all-to-one: every core sends its id DIRECTLY to the collector at
 * tile (0,0), then spins doing NOTHING (no relay code). The collector counts
 * arrivals and emits the running count. HW router: all N-1 arrive (hardware
 * forwards past every tile). SW mesh: only (0,0)'s adjacent neighbors arrive —
 * a direct non-adjacent send has no relay, so it never reaches the collector. */
#include "mailbox.h"
void main(void){
    uint32_t y=mb_my_y(), x=mb_my_x();
    MB_CORE_BUSY=0u;
    if (y==0u && x==0u){
        uint32_t n=0u;
        for(;;){
            while(MB_READY==0u){}
            uint32_t s=mb_lowbit(MB_READY); (void)MB_SLOT(s,1); MB_DONE=s;
            n++;
            mb_display(0u, 0xC0110000u | n);     /* collector: running arrival count */
        }
    } else {
        mb_post1(0u, 0u, (y<<4)|x);              /* send my id to (0,0), non-adjacent for most */
        for(;;){}                                /* spin — NO relay, NO compute help */
    }
}
