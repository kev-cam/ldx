// worker.c — generic mesh-node firmware. Every core runs the same loop:
//   forward non-local messages, dispatch local ones. No caller behavior;
//   wander_calls come from the host through the boundary FIFOs.
//
// Function table:
//   FN_INC    = 3  ret = args[0] + 1
//   FN_DOUBLE = 2  ret = args[0] * 2

#include "mesh.h"

#define FN_DOUBLE 2
#define FN_INC    3

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
    case FN_DOUBLE: if (argc) ret = args[0] * 2; break;
    case FN_INC:    if (argc) ret = args[0] + 1; break;
    default: break;
    }

    if (op == OP_CALL) {
        int rd = mesh_route(sx, sy);
        uint32_t rh = mesh_hdr(sx, sy, my_x(), my_y(), OP_RETURN, fn, 1, tag);
        mesh_send_msg(rd, rh, &ret, 1);
    }
}

void main(void) {
    for (;;) {
        int d = mesh_poll_inbound();
        if (d < 0) continue;
        uint32_t hdr = mesh_pop(d);
        if (HDR_DEST_X(hdr) == my_x() && HDR_DEST_Y(hdr) == my_y())
            dispatch(hdr, d);
        else
            mesh_forward(d, hdr);
    }
}
