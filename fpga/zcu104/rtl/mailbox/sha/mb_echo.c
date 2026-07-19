#include "mailbox.h"
void main(void){
    uint32_t t0 = (mb_my_y()==0u && mb_my_x()==0u);
    MB_CORE_BUSY=0u;
    for(;;){
        while(MB_READY==0u){}
        uint32_t s=mb_lowbit(MB_READY); uint32_t v=MB_SLOT(s,1); MB_DONE=s;
        if(t0) mb_display(0u, v);     /* echo received payload back to egress */
    }
}
