// ldx_rt.c — AArch64 runtime-patching primitives.
//
// AArch64 fixed-size 32-bit instructions; aligned 4-byte stores are
// architecturally atomic. The smallest possible redirect is a single
// `B label` (opcode 000101 + 26-bit signed word offset, ±128 MB range).
// Caches: aarch64 has separate I/D caches; after writing through D-side
// we need DC CVAU + IC IVAU + ISB. GCC's __builtin___clear_cache emits
// exactly that sequence on aarch64.

#include "ldx_rt.h"

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#include <unistd.h>

int ldx_patch_b(void *site, void *target) {
    uintptr_t s = (uintptr_t)site;
    uintptr_t t = (uintptr_t)target;
    int64_t off = (int64_t)t - (int64_t)s;

    if ((s & 3u) != 0 || (off & 3) != 0) return -1;
    // imm26 reaches ±(1 << 27) bytes from PC
    if (off < -(int64_t)(1LL << 27) || off >= (int64_t)(1LL << 27)) return -2;

    uint32_t insn = 0x14000000u | ((uint32_t)(off >> 2) & 0x03FFFFFFu);

    long pgsz = sysconf(_SC_PAGESIZE);
    uintptr_t pg_lo = s & ~((uintptr_t)pgsz - 1);
    // 4 bytes fits in one page if site is at least 4 bytes from page-end,
    // otherwise we need two pages of cover.
    size_t span = ((s + 4) > (pg_lo + (uintptr_t)pgsz)) ? (size_t)(2 * pgsz)
                                                       : (size_t)pgsz;

    if (mprotect((void *)pg_lo, span,
                 PROT_READ | PROT_WRITE | PROT_EXEC) < 0) return -3;

    *(volatile uint32_t *)site = insn;
    __builtin___clear_cache((char *)site, (char *)site + 4);

    if (mprotect((void *)pg_lo, span, PROT_READ | PROT_EXEC) < 0) return -4;

    return 0;
}

int ldx_patch_function(void *func, void *replacement) {
    return ldx_patch_b(func, replacement);
}
