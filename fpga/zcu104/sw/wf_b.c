// wf_b.c — Core at (1,0): receive loop. Forward non-local msgs; dispatch local fn.
#include "mesh.h"

#define RESULT (*(volatile uint32_t *)0x80000FFC)

#define FN_LOG 1

static void handle(uint32_t hdr, int in_dir) {
    unsigned fn = HDR_FN(hdr);
    unsigned argc = HDR_ARGC(hdr);
    uint32_t args[8];
    mesh_read_args(in_dir, args, argc);

    switch (fn) {
    case FN_LOG:
        if (argc >= 1) RESULT = args[0];
        break;
    default:
        break;
    }
}

void main(void) {
    for (;;) {
        int d = mesh_poll_inbound();
        if (d < 0) continue;
        uint32_t hdr = mesh_pop(d);
        if (HDR_DEST_X(hdr) == MY_X && HDR_DEST_Y(hdr) == MY_Y) {
            handle(hdr, d);
        } else {
            mesh_forward(d, hdr);
        }
    }
}
