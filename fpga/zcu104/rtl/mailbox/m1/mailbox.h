#ifndef MAILBOX_H
#define MAILBOX_H
#include <stdint.h>
#define MB_BASE 0xF0000000u
#define MB_REG(o)     (*(volatile uint32_t*)(MB_BASE+(o)))
#define MB_SEND_W0     MB_REG(0x00)   /* W: outgoing word0          */
#define MB_SEND_D1     MB_REG(0x04)   /* W: payload (write fires)   */
#define MB_READY       MB_REG(0x08)   /* R: ready bitmap            */
#define MB_FREE        MB_REG(0x0C)   /* R: free bitmap             */
#define MB_SLOT_LIMIT  MB_REG(0x10)
#define MB_MBOX_BASE   MB_REG(0x14)
#define MB_REGION_BASE MB_REG(0x18)
#define MB_DONE        MB_REG(0x1C)   /* W: free a drained slot        */
#define MB_CORE_BUSY   MB_REG(0x20)   /* RW: worker declares busy/done */
#define MB_CYCLE_CNT   MB_REG(0x24)   /* R: ++ on each barrier advance */
#define MB_MY_YX       MB_REG(0x40)
#define MB_SLOT(s,w)   (*(volatile uint32_t*)(MB_BASE+0x800u+((s)*16u)+((w)*4u)))

static inline uint32_t mb_w0(uint32_t y,uint32_t x,uint32_t size){
    return (y<<16)|(x<<8)|(size&0xFFu);
}
static inline void mb_post1(uint32_t y,uint32_t x,uint32_t payload){
    MB_SEND_W0 = mb_w0(y,x,1u);
    MB_SEND_D1 = payload;             /* the SEND_D1 write fires the direct send */
}
/* $display lowers to an off-array message: handle in dst, value as payload.
 * The host-bridge (TB in sim) holds the format keyed by the call-site handle. */
static inline void mb_display(uint32_t handle, uint32_t value){
    MB_SEND_W0 = (1u<<31) | ((handle&0xFFFFu)<<8) | 1u;   /* off_array, handle, size=1 */
    MB_SEND_D1 = value;
}
static inline uint32_t mb_my_y(void){ return (MB_MY_YX>>4)&0xFu; }
static inline uint32_t mb_my_x(void){ return MB_MY_YX&0xFu; }
static inline uint32_t mb_lowbit(uint32_t v){ uint32_t i=0; while(!(v&1u)){v>>=1;i++;} return i; }
#endif
