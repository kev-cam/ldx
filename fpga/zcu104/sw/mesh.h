// mesh.h — wander_fire / wander_call primitives for ldx mesh nodes.
//
// Header word (32 bits, MSB-first):
//   [31:29] dest_x   (0..6 valid; this build uses only inner 5×5)
//   [28:26] dest_y
//   [25:23] src_x
//   [22:20] src_y
//   [19:18] op       (0=fire, 1=call, 2=return)
//   [17:10] fn_id
//   [9:7]   argc     (0..7)
//   [6:0]   ret_tag  (caller-allocated; matched by sender on return)
//
// MMIO map per direction (d ∈ {0=N, 1=E, 2=S, 3=W}):
//   0xF0000100 + 0x10*d   PUSH_DATA
//   0xF0000104 + 0x10*d   PUSH_STATUS  bit0 = full
//   0xF0000108 + 0x10*d   POP_DATA
//   0xF000010C + 0x10*d   POP_STATUS   bit0 = empty

#ifndef LDX_MESH_H
#define LDX_MESH_H

#include <stdint.h>

#define DIR_N 0
#define DIR_E 1
#define DIR_S 2
#define DIR_W 3

#define MESH_REG(d, off) (*(volatile uint32_t *)(0xF0000100u + 0x10u*(d) + (off)))
#define PUSH_DATA(d)     MESH_REG(d, 0x00)
#define PUSH_STATUS(d)   MESH_REG(d, 0x04)
#define POP_DATA(d)      MESH_REG(d, 0x08)
#define POP_STATUS(d)    MESH_REG(d, 0x0C)

#define OP_FIRE   0
#define OP_CALL   1
#define OP_RETURN 2

static inline uint32_t mesh_hdr(unsigned dx, unsigned dy, unsigned sx, unsigned sy,
                                unsigned op, unsigned fn, unsigned argc, unsigned tag) {
    return ((dx & 7u) << 29) | ((dy & 7u) << 26)
         | ((sx & 7u) << 23) | ((sy & 7u) << 20)
         | ((op & 3u) << 18) | ((fn & 0xFFu) << 10)
         | ((argc & 7u) << 7) | (tag & 0x7Fu);
}

#define HDR_DEST_X(h) (((h) >> 29) & 7u)
#define HDR_DEST_Y(h) (((h) >> 26) & 7u)
#define HDR_SRC_X(h)  (((h) >> 23) & 7u)
#define HDR_SRC_Y(h)  (((h) >> 20) & 7u)
#define HDR_OP(h)     (((h) >> 18) & 3u)
#define HDR_FN(h)     (((h) >> 10) & 0xFFu)
#define HDR_ARGC(h)   (((h) >>  7) & 7u)
#define HDR_TAG(h)    ( (h)        & 0x7Fu)

// Runtime core identity, read from MMIO at 0xF0000040.
#define MY_ID (*(volatile uint32_t *)0xF0000040)
static inline unsigned my_x(void) { return MY_ID & 7u; }
static inline unsigned my_y(void) { return (MY_ID >> 3) & 7u; }

#define MY_X my_x()
#define MY_Y my_y()

// XY routing: route X first, then Y. Returns direction toward (dx,dy), or
// -1 if (dx,dy) == (my_x(), my_y()).
static inline int mesh_route(unsigned dx, unsigned dy) {
    unsigned mx = my_x(), my = my_y();
    if (dx > mx) return DIR_E;
    if (dx < mx) return DIR_W;
    if (dy > my) return DIR_N;
    if (dy < my) return DIR_S;
    return -1;
}

// Push one word to a direction, busy-waiting if full.
static inline void mesh_push(int dir, uint32_t v) {
    while (PUSH_STATUS(dir) & 1u) { }
    PUSH_DATA(dir) = v;
}

// Pop one word from a direction, busy-waiting if empty.
static inline uint32_t mesh_pop(int dir) {
    while (POP_STATUS(dir) & 1u) { }
    return POP_DATA(dir);
}

// Send a multi-word message out a given direction (no routing decision here).
static inline void mesh_send_msg(int dir, uint32_t hdr, const uint32_t *args, unsigned argc) {
    mesh_push(dir, hdr);
    for (unsigned i = 0; i < argc; i++) mesh_push(dir, args[i]);
}

// Try once: poll all 4 inbound ports, return -1 if all empty, else the dir
// that had a header ready (caller is responsible for reading args off that dir).
static inline int mesh_poll_inbound(void) {
    for (int d = 0; d < 4; d++) {
        if (!(POP_STATUS(d) & 1u)) return d;
    }
    return -1;
}

// Read the args following a header (already popped) from `dir`.
static inline void mesh_read_args(int dir, uint32_t *args, unsigned argc) {
    for (unsigned i = 0; i < argc; i++) args[i] = mesh_pop(dir);
}

// Forward a header (and its args) out the appropriate next-hop direction
// (do XY routing toward HDR_DEST_*).
static inline void mesh_forward(int in_dir, uint32_t hdr) {
    int out = mesh_route(HDR_DEST_X(hdr), HDR_DEST_Y(hdr));
    unsigned argc = HDR_ARGC(hdr);
    mesh_push(out, hdr);
    for (unsigned i = 0; i < argc; i++) mesh_push(out, mesh_pop(in_dir));
}

#endif
