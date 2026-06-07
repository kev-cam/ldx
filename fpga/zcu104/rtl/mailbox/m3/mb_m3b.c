/* mb_m3b.c — M3b: combinational signals + within-cycle delta settling across a
 * core boundary, hand-lowered. Clocked state is double-buffered; comb signals are
 * recomputed each cycle and ripple A->B->A *within* one simulated cycle:
 *
 *   core A:  cnt   <= cnt + 1            (registered, active/inactive by parity)
 *            s1     = cnt + 7            (comb)         -- post to B
 *            result = s3 & 0xFF          (comb)         -- $display
 *   core B:  s2     = s1 ^ 3             (comb)
 *            s3     = s2 + 1             (comb)         -- post back to A
 *
 *   result(cnt) = (((cnt+7) ^ 3) + 1) & 0xFF
 *
 * A goes busy, posts s1, then blocks on s3 (still busy) — so the barrier cannot
 * advance until the comb has rippled through both cores and settled. */
#include "mailbox.h"
#define ARRAY_X 2
volatile uint32_t *const CNT    = (uint32_t *)0x80000F10u;   /* cnt[2] (double buffer) */
volatile uint32_t *const RESULT = (uint32_t *)0x80000F00u;

static uint32_t recv_word(void){
    while (MB_READY == 0u){}
    uint32_t slot = mb_lowbit(MB_READY);
    uint32_t v = MB_SLOT(slot,1);
    MB_DONE = slot;
    return v;
}

void main(void){
    uint32_t id = (mb_my_y()*ARRAY_X) + mb_my_x();
    if (id == 0u){                                 /* core A */
        CNT[0]=0u; CNT[1]=0u;
        for(;;){
            MB_CORE_BUSY = 1u;
            uint32_t c0  = MB_CYCLE_CNT;
            uint32_t p   = c0 & 1u;
            uint32_t cnt = CNT[p];                  /* active */
            uint32_t s1  = cnt + 7u;                /* comb */
            mb_post1(0u, 1u, s1);                   /* s1 -> B */
            uint32_t s3  = recv_word();             /* <- B, same cycle (delta) */
            uint32_t result = s3 & 0xFFu;           /* comb */
            mb_display(0u, result);                 /* $display(result) */
            CNT[p^1u] = cnt + 1u;                   /* registered: next cnt */
            RESULT[0] = result;
            MB_CORE_BUSY = 0u;
            while (MB_CYCLE_CNT == c0){}
        }
    } else if (id == 1u){                           /* core B */
        for(;;){
            MB_CORE_BUSY = 1u;
            uint32_t c0 = MB_CYCLE_CNT;
            uint32_t s1 = recv_word();              /* <- A */
            uint32_t s2 = s1 ^ 3u;                  /* comb */
            uint32_t s3 = s2 + 1u;                  /* comb */
            mb_post1(0u, 0u, s3);                   /* s3 -> A */
            MB_CORE_BUSY = 0u;
            while (MB_CYCLE_CNT == c0){}
        }
    } else { MB_CORE_BUSY = 0u; for(;;){} }
}
