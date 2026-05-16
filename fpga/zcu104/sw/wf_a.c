// wf_a.c — Core at (0,0): fire fn=1 with arg 0xCAFEBABE at (1,0) and park.
#include "mesh.h"

#define RESULT (*(volatile uint32_t *)0x80000FFC)

#define FN_LOG 1

void main(void) {
    uint32_t arg = 0xCAFEBABE;
    int dir = mesh_route(1, 0);             // east
    uint32_t hdr = mesh_hdr(1, 0, MY_X, MY_Y, OP_FIRE, FN_LOG, 1, 0);
    mesh_send_msg(dir, hdr, &arg, 1);
    RESULT = 0x00000A0Au;                   // "fired" sentinel
    for (;;) { }
}
