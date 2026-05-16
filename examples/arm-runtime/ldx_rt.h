// ldx_rt.h — minimal runtime-patching API for AArch64 LDX.
//
// First milestone of "make LDX capable of ARM runtime editing": patch
// individual call sites and function entries inside a running process.

#ifndef LDX_RT_H
#define LDX_RT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

// Overwrite the 32-bit instruction at `site` with an unconditional branch
// (`B target`) to `target`. Handles mprotect, I-cache flush, and the
// ISB barrier. Returns:
//    0  success
//   -1  target offset not 4-byte aligned
//   -2  target out of ±128 MB range from site
//   -3  mprotect (RW+X) failed
//   -4  mprotect (R+X) failed
int ldx_patch_b(void *site, void *target);

// Convenience: patch a *function entry* to redirect all calls to `replacement`.
// `func` is the symbol address (e.g. the literal name in a static binary).
int ldx_patch_function(void *func, void *replacement);

#ifdef __cplusplus
}
#endif

#endif
