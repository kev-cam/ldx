/* mb_relay.c — software copy-through over nearest-neighbor mailboxes. Each core
 * sits in a mailbox-checker loop; a packet carries its FINAL (y,x) and is relayed
 * one adjacent hop at a time (XY routing) until it reaches the destination, whose
 * software consumes it. Tile (0,0) initiates one packet to DEST_YX. The fabric
 * only ever sees adjacent sends, so this software is unchanged when the flat
 * router is later replaced by the real nearest-neighbor mesh. */
#include "mailbox.h"
#ifndef DEST_YX
#define DEST_YX 0x33u            /* (3,3) for a 4x4 */
#endif
volatile uint32_t *const RESULT = (uint32_t *)0x80000F00u;
static uint32_t myx_g;

static void send_toward(uint32_t final_yx, uint32_t data){
    uint32_t myy=(myx_g>>4)&0xFu, mx=myx_g&0xFu;
    uint32_t fy=(final_yx>>4)&0xFu, fx=final_yx&0xFu;
    uint32_t ny=myy, nx=mx;
    if      (fx>mx)  nx=mx+1u;     /* XY: move in X first, then Y — one adjacent hop */
    else if (fx<mx)  nx=mx-1u;
    else if (fy>myy) ny=myy+1u;
    else if (fy<myy) ny=myy-1u;
    mb_post1(ny, nx, (final_yx<<24) | (data & 0xFFFFFFu));   /* dst = an ADJACENT tile */
}
void main(void){
    myx_g = MB_MY_YX;
    RESULT[0]=0u; RESULT[1]=0u;
    if (myx_g == 0x00u) send_toward(DEST_YX, 0xABCDu);       /* (0,0) initiates */
    for(;;){                                                  /* mailbox-checker loop */
        if (MB_READY != 0u){
            uint32_t slot=mb_lowbit(MB_READY);
            uint32_t w=MB_SLOT(slot,1);
            MB_DONE=slot;
            uint32_t fyx=(w>>24)&0xFFu, data=w&0xFFFFFFu;
            if (fyx == myx_g){ RESULT[0]=data; RESULT[1]=RESULT[1]+1u; }   /* arrived */
            else send_toward(fyx, data);                                   /* relay */
        }
    }
}
