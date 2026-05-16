// wc_b.c — Core (1,0): receive loop dispatching FN_DOUBLE (returns 2x arg).
#include "mesh.h"

#define RESULT (*(volatile uint32_t *)0x80000FFC)

#define FN_LOG    1
#define FN_DOUBLE 2

static void dispatch(uint32_t hdr, int dir) {
    unsigned fn   = HDR_FN(hdr);
    unsigned argc = HDR_ARGC(hdr);
    unsigned op   = HDR_OP(hdr);
    unsigned tag  = HDR_TAG(hdr);
    unsigned sx   = HDR_SRC_X(hdr);
    unsigned sy   = HDR_SRC_Y(hdr);
    uint32_t args[8];
    mesh_read_args(dir, args, argc);

    uint32_t ret = 0;
    switch (fn) {
    case FN_LOG:    if (argc) RESULT = args[0]; break;
    case FN_DOUBLE: if (argc) ret = args[0] * 2; break;
    default: break;
    }

    if (op == OP_CALL) {
        int rd = mesh_route(sx, sy);
        uint32_t rh = mesh_hdr(sx, sy, MY_X, MY_Y, OP_RETURN, fn, 1, tag);
        mesh_send_msg(rd, rh, &ret, 1);
        RESULT = ret;   // sentinel: "served a call, returned this"
    }
}

void main(void) {
    for (;;) {
        int d = mesh_poll_inbound();
        if (d < 0) continue;
        uint32_t hdr = mesh_pop(d);
        if (HDR_DEST_X(hdr) == MY_X && HDR_DEST_Y(hdr) == MY_Y)
            dispatch(hdr, d);
        else
            mesh_forward(d, hdr);
    }
}
