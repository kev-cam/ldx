/* mb_worker.c — M1: send a packet to ourselves (TB loops egress->ingress),
 * receive it back through the mailbox, and stash the result for the TB. */
#include "mailbox.h"
volatile uint32_t *const RESULT = (volatile uint32_t *)0x80000F00u; /* dpram[0x3C0] */

void main(void){
    uint32_t y = mb_my_y(), x = mb_my_x();
    RESULT[2] = 0u;
    mb_post1(y, x, 0xABCD1234u);          /* fire a self-addressed packet     */
    RESULT[2] = 1u;
    uint32_t r;
    while ((r = MB_READY) == 0u) { }      /* spin until it comes back         */
    uint32_t slot = mb_lowbit(r);
    uint32_t w0   = MB_SLOT(slot, 0);
    uint32_t pay  = MB_SLOT(slot, 1);
    MB_DONE = slot;                        /* free the slot                    */
    RESULT[0] = pay;                       /* TB checks == 0xABCD1234          */
    RESULT[1] = w0;                        /* received header                  */
    RESULT[2] = 0xD09Eu;                   /* done marker                      */
    for(;;){ }
}
