#ifndef LDX_H
#define LDX_H

#include <stddef.h>

/*
 * ldx — Programmable linker extensions via LD_PRELOAD + GOT patching.
 *
 * Provides runtime symbol replacement and instrumentation callbacks
 * without recompilation or source access.
 */

/* Replace a dynamically-linked symbol at runtime.
 *
 * target formats:
 *   "sin"              — replace all GOT entries for sin across all objects
 *   "libm.so.6:sin"    — replace sin only where it resolves from libm
 *
 * Returns the original function pointer, or NULL on failure.
 */
void *dlreplace(const char *target, void *replacement);

/* Query-based replacement with callback.
 *
 * The callback is invoked for each symbol matching `pattern` (glob).
 * It receives (symbol_name, library_name, current_address) and returns
 * the replacement address, or NULL to keep the original.
 */
typedef void *(*dlreplaceq_cb)(const char *sym, const char *lib, void *cur);
int dlreplaceq(const char *pattern, dlreplaceq_cb callback);

/* Instrumentation callback, fired on entry/exit of shimmed functions. */
typedef void (*ldx_hook_fn)(const char *sym, const char *lib,
                            int is_exit, unsigned long thread_id,
                            double timestamp);

/* Register an entry/exit hook for the given target (same format as dlreplace).
 * The hook fires around the *current* function at that GOT slot.
 * Returns 0 on success, -1 on failure.
 */
int ldx_add_hook(const char *target, ldx_hook_fn hook);

/* Walk all GOT entries across loaded objects.  Calls `cb` for each.
 * cb receives (symbol_name, library_name, got_entry_address, current_value).
 * Return 0 from cb to continue, nonzero to stop.
 */
typedef int (*ldx_walk_cb)(const char *sym, const char *lib,
                           void **got_slot, void *cur_val, void *user);
int ldx_walk_got(ldx_walk_cb cb, void *user);

/* Initialize ldx (called automatically via constructor when LD_PRELOADed,
 * or manually if linked directly). */
void ldx_init(void);

/* ---------- Profiler (Phase 1.4) ---------- */

/* Per-function profiling stats. */
typedef struct {
    const char    *sym;
    const char    *lib;
    unsigned long  call_count;
    double         total_time;    /* cumulative wall-clock seconds */
    double         min_time;
    double         max_time;
} ldx_prof_entry_t;

/* Start profiling the given target (same format as dlreplace).
 * Installs an entry/exit trampoline that collects timing.
 * Returns 0 on success, -1 on failure. */
int ldx_prof_add(const char *target);

/* Print profiling report to stderr. */
void ldx_prof_report(void);

/* Get profiling data.  Returns number of entries.
 * If entries is non-NULL, fills up to max_entries. */
int ldx_prof_get(ldx_prof_entry_t *entries, int max_entries);

/* Reset all profiling counters. */
void ldx_prof_reset(void);

#endif /* LDX_H */
