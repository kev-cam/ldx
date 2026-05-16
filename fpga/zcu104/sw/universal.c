// universal.c — one binary loaded into every core of the mesh.
// Caller behavior is gated on (my_x, my_y) == (1, 1).

#include "mesh.h"

#define RESULT (*(volatile uint32_t *)0x80000FFC)

#define FN_DOUBLE 2

static void responder_dispatch(uint32_t hdr, int dir) {
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
    default: break;
    }

    if (op == OP_CALL) {
        int rd = mesh_route(sx, sy);
        uint32_t rh = mesh_hdr(sx, sy, my_x(), my_y(), OP_RETURN, fn, 1, tag);
        mesh_send_msg(rd, rh, &ret, 1);
    }
}

static uint32_t wander_call(unsigned dx, unsigned dy, unsigned fn,
                            unsigned argc, const uint32_t *args) {
    static unsigned next_tag = 0;
    unsigned tag = (++next_tag) & 0x7F;
    if (tag == 0) tag = 1;
    int out = mesh_route(dx, dy);
    uint32_t hdr = mesh_hdr(dx, dy, my_x(), my_y(), OP_CALL, fn, argc, tag);
    mesh_send_msg(out, hdr, args, argc);
    for (;;) {
        int d = mesh_poll_inbound();
        if (d < 0) continue;
        uint32_t h = mesh_pop(d);
        if (HDR_DEST_X(h) == my_x() && HDR_DEST_Y(h) == my_y()) {
            if (HDR_OP(h) == OP_RETURN && HDR_TAG(h) == tag) {
                uint32_t ret = 0;
                unsigned ac = HDR_ARGC(h);
                if (ac >= 1) ret = mesh_pop(d);
                for (unsigned i = 1; i < ac; i++) (void)mesh_pop(d);
                return ret;
            }
            responder_dispatch(h, d);
        } else {
            mesh_forward(d, h);
        }
    }
}

#define FN_LOG    1

void main(void) {
    if (my_x() == 1 && my_y() == 1) {
        uint32_t arg = 21;
        uint32_t r = wander_call(5, 5, FN_DOUBLE, 1, &arg);
        RESULT = r;                // expected: 42

        // Push result out to host via W edge: dest (0,1)
        uint32_t hdr = mesh_hdr(0, 1, my_x(), my_y(), OP_FIRE, FN_LOG, 1, 0);
        mesh_send_msg(DIR_W, hdr, &r, 1);
        for (;;) { }
    } else {
        for (;;) {
            int d = mesh_poll_inbound();
            if (d < 0) continue;
            uint32_t hdr = mesh_pop(d);
            if (HDR_DEST_X(hdr) == my_x() && HDR_DEST_Y(hdr) == my_y())
                responder_dispatch(hdr, d);
            else
                mesh_forward(d, hdr);
        }
    }
}
