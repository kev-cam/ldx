// wc_a.c — Core (0,0): wander_call FN_DOUBLE(21) on (1,0). Expect 42.
#include "mesh.h"

#define RESULT (*(volatile uint32_t *)0x80000FFC)

#define FN_LOG    1
#define FN_DOUBLE 2

static void dispatch(uint32_t hdr, int dir);

static uint32_t wander_call(unsigned dx, unsigned dy, unsigned fn,
                            unsigned argc, const uint32_t *args) {
    static unsigned next_tag = 0;
    unsigned tag = (++next_tag) & 0x7F;
    if (tag == 0) tag = 1;
    int out = mesh_route(dx, dy);
    uint32_t hdr = mesh_hdr(dx, dy, MY_X, MY_Y, OP_CALL, fn, argc, tag);
    mesh_send_msg(out, hdr, args, argc);
    for (;;) {
        int d = mesh_poll_inbound();
        if (d < 0) continue;
        uint32_t h = mesh_pop(d);
        if (HDR_DEST_X(h) == MY_X && HDR_DEST_Y(h) == MY_Y) {
            if (HDR_OP(h) == OP_RETURN && HDR_TAG(h) == tag) {
                uint32_t ret = 0;
                unsigned ac = HDR_ARGC(h);
                if (ac >= 1) ret = mesh_pop(d);
                for (unsigned i = 1; i < ac; i++) (void)mesh_pop(d);
                return ret;
            }
            dispatch(h, d);
        } else {
            mesh_forward(d, h);
        }
    }
}

static void dispatch(uint32_t hdr, int dir) {
    unsigned fn = HDR_FN(hdr);
    unsigned argc = HDR_ARGC(hdr);
    uint32_t args[8];
    mesh_read_args(dir, args, argc);
    (void)fn;
    (void)args;
}

void main(void) {
    uint32_t arg = 21;
    uint32_t r = wander_call(1, 0, FN_DOUBLE, 1, &arg);
    RESULT = r;
    for (;;) { }
}
