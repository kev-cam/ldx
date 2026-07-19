/* mb_m3a.c — M3a: clocked 2-core design, hand-lowered onto the event loop.
 *   core A (id 0): registered counter `count` (double-buffered active/inactive);
 *                  each cycle posts the active count to core B.
 *   core B (id 1): receives count and $display()s it (off-array -> host-bridge).
 * The active/inactive half is chosen by the cycle parity (CYCLE_CNT & 1) — the
 * software double-buffer; the barrier's parity flip makes the inactive write
 * the next cycle's active value. Clocked-only, no delta cycles. */
#include "mailbox.h"
#define ARRAY_X 2
volatile uint32_t *const CNT    = (uint32_t *)0x80000F10u;  /* count[2] in BRAM */
volatile uint32_t *const RESULT = (uint32_t *)0x80000F00u;

void main(void){
    uint32_t id = (mb_my_y()*ARRAY_X) + mb_my_x();
    if (id == 0u){                          /* core A: count <= count+1 */
        CNT[0]=0u; CNT[1]=0u;
        for(;;){
            MB_CORE_BUSY = 1u;
            uint32_t c0  = MB_CYCLE_CNT;
            uint32_t p   = c0 & 1u;          /* active half */
            uint32_t cur = CNT[p];
            mb_post1(0u, 1u, cur);           /* send active count to B (0,1) */
            CNT[p^1u] = cur + 1u;            /* NBA: next value -> inactive half */
            RESULT[0] = cur;
            MB_CORE_BUSY = 0u;
            while (MB_CYCLE_CNT == c0){}
        }
    } else if (id == 1u){                    /* core B: $display(count) */
        uint32_t n=0u;
        for(;;){
            MB_CORE_BUSY = 1u;
            uint32_t c0 = MB_CYCLE_CNT;
            while (MB_READY == 0u){}
            uint32_t slot = mb_lowbit(MB_READY);
            uint32_t v    = MB_SLOT(slot,1);
            MB_DONE = slot;
            mb_display(0u, v);               /* $display: off-array to host-bridge */
            RESULT[0]=v; RESULT[1]=++n;
            MB_CORE_BUSY = 0u;
            while (MB_CYCLE_CNT == c0){}
        }
    } else {
        MB_CORE_BUSY = 0u; for(;;){}
    }
}
