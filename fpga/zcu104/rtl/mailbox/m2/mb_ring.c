/* mb_ring.c — M2 ring worker: each node sends to (id+1)%16 and receives from
 * (id-1)%16 each simulated cycle, declaring busy/done so the barrier advances. */
#include "mailbox.h"
volatile uint32_t *const RESULT = (volatile uint32_t *)0x80000F00u; /* dpram[0x3C0] */

void main(void){
    uint32_t y = mb_my_y(), x = mb_my_x();
    uint32_t id  = (y<<2)|x;                 /* ARRAY_X=4 */
    uint32_t nid = (id+1u)&15u;              /* ring successor */
    uint32_t ny  = nid>>2, nx = nid&3u;
    uint32_t recv = 0u, cyc = 0u;
    RESULT[1] = id;
    for(;;){
        MB_CORE_BUSY = 1u;                   /* busy this cycle */
        uint32_t c0 = MB_CYCLE_CNT;
        mb_post1(ny, nx, (id<<16)|cyc);      /* send to successor */
        while (MB_READY == 0u) { }           /* wait for predecessor's msg */
        uint32_t slot = mb_lowbit(MB_READY);
        uint32_t pay  = MB_SLOT(slot, 1);
        MB_DONE = slot;
        recv++; cyc++;
        RESULT[0] = recv;
        RESULT[2] = pay;
        MB_CORE_BUSY = 0u;                   /* done this cycle */
        while (MB_CYCLE_CNT == c0) { }       /* wait for the barrier to advance */
    }
}
