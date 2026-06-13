//
//  ldx_hal.h — target-independent runtime HAL for nvc-cppgen output.
//
//  The emitted per-process C++ (from `nvc -e --emit-cpp`) is portable and calls
//  only this API.  Each target (the ZCU104 VexRiscv mailbox array now;
//  Tenstorrent etc. later) provides an implementation that maps these onto its
//  clock/barrier, signal memory, and message fabric.  No strings cross to the
//  array: ldx_io_emit ships a host-registry id + raw args (mechanism TBD).
//
#ifndef LDX_HAL_H
#define LDX_HAL_H

#include <stdint.h>

typedef struct ldx_hal ldx_hal_t;   // opaque per-core runtime context

typedef void (*ldx_proc_fn)(void *state, ldx_hal_t *hal, int32_t resume);

#ifdef __cplusplus
extern "C" {
#endif

// Elaboration: create a signal (returns an opaque handle), connect a mapped
// out-port net (src drives dst), and register a process with its context.
void   *ldx_init_signal(ldx_hal_t *hal, int64_t count, int64_t size,
                        int64_t value, int64_t flags);
void    ldx_map_signal(ldx_hal_t *hal, void *src, void *dst);
void    ldx_register_process(ldx_proc_fn fn, void *state, void *ctx);

// Reach a variable/signal handle in the parent instance context (hops up,
// slot nth).  Returns a pointer to the slot; the emitted code derefs it.
void   *ldx_var_upref(void *ctx, int64_t hops, int64_t nth);

// Signal access.  Handles are opaque (void *).
void   *ldx_resolved(ldx_hal_t *hal, void *sig);                 // -> value ptr
void    ldx_drive_signal(ldx_hal_t *hal, void *sig, int64_t count);
void    ldx_sched_waveform(ldx_hal_t *hal, void *sig, int64_t count,
                           int64_t value, int64_t reject, int64_t after);
void    ldx_sched_event(ldx_hal_t *hal, void *sig, int64_t count);

// Time / wakeup.
void    ldx_sched_process(ldx_hal_t *hal, int64_t delay);        // wait for

// Edge / value sensitivity triggers (must be honoured, not no-ops).
int32_t ldx_cmp_trigger(ldx_hal_t *hal, void *sig, int64_t value);
void    ldx_add_trigger(ldx_hal_t *hal, int32_t trig);

// Fire-and-forget host I/O ($display/report): string_id resolves to a format
// in the host registry; raw args ship as scalars.  Never blocks the core.
void    ldx_io_emit(ldx_hal_t *hal, uint32_t string_id, int64_t arg0);
void    ldx_fail(ldx_hal_t *hal);   // assertion failure (>= ERROR): stop the sim

// Heap for VHDL composite temporaries / access types (new, alloc).  Returns a
// zeroed, pointer-aligned block.  On the array this bumps a fixed arena.
void   *ldx_alloc(ldx_hal_t *hal, int64_t nbytes);

// Shared zeroed scratch region used as the placeholder address for unlowered
// pointer-typed ops, so a stray deref/index reads zero instead of faulting.
// No hal needed (callable from emitted pure functions).
void   *ldx_scratch(void);

#ifdef __cplusplus
}
#endif

#endif  // LDX_HAL_H
