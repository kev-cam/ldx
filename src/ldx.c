#define _GNU_SOURCE
#include "ldx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <elf.h>
#include <link.h>
#include <sys/mman.h>
#include <unistd.h>
#include <fnmatch.h>
#include <pthread.h>
#include <time.h>

/* ---------- internal types ---------- */

/* Parsed target: "libm.so.6:sin" → lib="libm.so.6", sym="sin"
 *                "sin"           → lib=NULL,        sym="sin"  */
typedef struct {
    const char *lib;   /* NULL means "any library" */
    char       *sym;
} parsed_target_t;

/* Per-object ELF dynamic info we extract once during walk. */
typedef struct {
    const char       *strtab;
    const ElfW(Sym)  *symtab;
    const ElfW(Rel)  *jmprel;     /* PLT relocations (JUMP_SLOT) */
    size_t            jmprel_count;
    const ElfW(Rel)  *dynrel;     /* DT_REL/DT_RELA relocations (GLOB_DAT etc.) */
    size_t            dynrel_count;
    int               is_rela;    /* 1 if DT_RELA-style entries */
    ElfW(Addr)        base;       /* load base for relocating r_offset */
} obj_dyn_t;

/* ---------- globals ---------- */

static int ldx_initialized = 0;
static long page_size;

/* ---------- helpers ---------- */

static void parse_target(const char *target, parsed_target_t *out)
{
    const char *colon = strchr(target, ':');
    if (colon) {
        size_t liblen = (size_t)(colon - target);
        char *lib = malloc(liblen + 1);
        memcpy(lib, target, liblen);
        lib[liblen] = '\0';
        out->lib = lib;
        out->sym = strdup(colon + 1);
    } else {
        out->lib = NULL;
        out->sym = strdup(target);
    }
}

static void free_target(parsed_target_t *t)
{
    free((char *)t->lib);
    free(t->sym);
}

/* Make a GOT slot writable, patch it, restore protection. */
static int patch_got_slot(void **slot, void *new_val)
{
    uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(page_size - 1);

    /* Try writing directly first (works if partial RELRO or no RELRO). */
    if (mprotect((void *)page, page_size, PROT_READ | PROT_WRITE) != 0) {
        perror("ldx: mprotect");
        return -1;
    }
    *slot = new_val;
    mprotect((void *)page, page_size, PROT_READ);
    return 0;
}

/* Relocate a dynamic entry address if needed.
 * On most objects, ld.so has already relocated d_un.d_ptr to absolute.
 * But some (vdso, pre-link) may have un-relocated offsets.
 * Heuristic: if ptr < base, it's unrelocated → add base. */
static uintptr_t relocate_ptr(ElfW(Addr) base, ElfW(Addr) ptr)
{
    if (ptr < base && base > 0)
        return (uintptr_t)(base + ptr);
    return (uintptr_t)ptr;
}

/* Extract dynamic linking tables from an object's program headers. */
static int extract_dyn(struct dl_phdr_info *info, obj_dyn_t *out)
{
    const ElfW(Dyn) *dyn = NULL;
    ElfW(Addr) base = info->dlpi_addr;

    memset(out, 0, sizeof(*out));
    out->base = base;

    /* Find PT_DYNAMIC */
    for (int i = 0; i < (int)info->dlpi_phnum; i++) {
        if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) {
            dyn = (const ElfW(Dyn) *)(base + info->dlpi_phdr[i].p_vaddr);
            break;
        }
    }
    if (!dyn) return -1;

    size_t pltrelsz = 0, relasz = 0, relsz = 0;
    int    pltrel_type = DT_REL;
    ElfW(Addr) raw_strtab = 0, raw_symtab = 0, raw_jmprel = 0;
    ElfW(Addr) raw_rela = 0, raw_rel = 0;

    for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
        case DT_STRTAB:   raw_strtab = d->d_un.d_ptr;       break;
        case DT_SYMTAB:   raw_symtab = d->d_un.d_ptr;       break;
        case DT_JMPREL:   raw_jmprel = d->d_un.d_ptr;       break;
        case DT_PLTRELSZ: pltrelsz = d->d_un.d_val;         break;
        case DT_PLTREL:   pltrel_type = (int)d->d_un.d_val; break;
        case DT_RELA:     raw_rela = d->d_un.d_ptr;         break;
        case DT_RELASZ:   relasz = d->d_un.d_val;           break;
        case DT_REL:      raw_rel = d->d_un.d_ptr;          break;
        case DT_RELSZ:    relsz = d->d_un.d_val;            break;
        }
    }

    if (!raw_strtab || !raw_symtab)
        return -1;

    /* Need at least one relocation section. */
    if (!raw_jmprel && !raw_rela && !raw_rel)
        return -1;

    out->strtab = (const char *)relocate_ptr(base, raw_strtab);
    out->symtab = (const ElfW(Sym) *)relocate_ptr(base, raw_symtab);

    /* On x86_64, DT_PLTREL tells us whether we use Rela or Rel.
     * DT_RELA/DT_REL sections use the same entry size. */
    out->is_rela = (pltrel_type == DT_RELA);
    if (!out->is_rela && raw_rela)
        out->is_rela = 1;  /* has DT_RELA section → it's rela */
    size_t relent = out->is_rela ? sizeof(ElfW(Rela)) : sizeof(ElfW(Rel));

    if (raw_jmprel && pltrelsz) {
        out->jmprel = (const ElfW(Rel) *)relocate_ptr(base, raw_jmprel);
        out->jmprel_count = pltrelsz / relent;
    }

    /* DT_RELA/DT_REL — contains GLOB_DAT, RELATIVE, COPY, etc. */
    if (out->is_rela && raw_rela && relasz) {
        out->dynrel = (const ElfW(Rel) *)relocate_ptr(base, raw_rela);
        out->dynrel_count = relasz / relent;
    } else if (!out->is_rela && raw_rel && relsz) {
        out->dynrel = (const ElfW(Rel) *)relocate_ptr(base, raw_rel);
        out->dynrel_count = relsz / relent;
    }

    return 0;
}

/* Get r_info and r_offset from a relocation entry in a table. */
static void rel_entry(const ElfW(Rel) *table, int is_rela, size_t idx,
                      ElfW(Addr) *r_info_out, ElfW(Addr) *r_offset_out)
{
    if (is_rela) {
        const ElfW(Rela) *r = (const ElfW(Rela) *)((const char *)table + idx * sizeof(ElfW(Rela)));
        *r_info_out = r->r_info;
        *r_offset_out = r->r_offset;
    } else {
        *r_info_out = table[idx].r_info;
        *r_offset_out = table[idx].r_offset;
    }
}

/* Get symbol name for a relocation entry.  Only returns names for
 * JUMP_SLOT and GLOB_DAT relocations (the patchable ones). */
static const char *rel_sym_name(const obj_dyn_t *od, const ElfW(Rel) *table, size_t idx)
{
    ElfW(Addr) r_info, r_offset;
    rel_entry(table, od->is_rela, idx, &r_info, &r_offset);

    unsigned type = ELF64_R_TYPE(r_info);
    if (type != R_X86_64_JUMP_SLOT && type != R_X86_64_GLOB_DAT)
        return NULL;

    size_t sym_idx = ELF64_R_SYM(r_info);
    if (sym_idx == 0) return NULL;
    return od->strtab + od->symtab[sym_idx].st_name;
}

/* Get GOT slot address for a relocation entry. */
static void **rel_got_slot(const obj_dyn_t *od, const ElfW(Rel) *table, size_t idx)
{
    ElfW(Addr) r_info, r_offset;
    rel_entry(table, od->is_rela, idx, &r_info, &r_offset);
    return (void **)relocate_ptr(od->base, r_offset);
}

/* ---------- GOT walk ---------- */

struct walk_ctx {
    ldx_walk_cb cb;
    void       *user;
    int         stop;
};

/* Walk one relocation table, calling the callback for each patchable entry. */
static int walk_rel_table(const obj_dyn_t *od, const ElfW(Rel) *table,
                          size_t count, const char *libname, struct walk_ctx *ctx)
{
    for (size_t i = 0; i < count; i++) {
        const char *sym = rel_sym_name(od, table, i);
        if (!sym || !*sym) continue;
        void **slot = rel_got_slot(od, table, i);
        if (!slot) continue;

        if (ctx->cb(sym, libname, slot, *slot, ctx->user) != 0) {
            ctx->stop = 1;
            return 1;
        }
    }
    return 0;
}

static int walk_one_object(struct dl_phdr_info *info, size_t size, void *data)
{
    (void)size;
    struct walk_ctx *ctx = data;
    if (ctx->stop) return 1;

    obj_dyn_t od;
    if (extract_dyn(info, &od) != 0) return 0;

    const char *libname = info->dlpi_name;
    if (!libname || !*libname) libname = "(main)";

    /* Walk PLT relocations (JUMP_SLOT). */
    if (od.jmprel && od.jmprel_count)
        walk_rel_table(&od, od.jmprel, od.jmprel_count, libname, ctx);

    /* Walk DT_RELA/DT_REL relocations (GLOB_DAT). */
    if (!ctx->stop && od.dynrel && od.dynrel_count)
        walk_rel_table(&od, od.dynrel, od.dynrel_count, libname, ctx);

    return ctx->stop ? 1 : 0;
}

int ldx_walk_got(ldx_walk_cb cb, void *user)
{
    struct walk_ctx ctx = { .cb = cb, .user = user, .stop = 0 };
    dl_iterate_phdr(walk_one_object, &ctx);
    return 0;
}

/* ---------- dlreplace ---------- */

struct replace_ctx {
    parsed_target_t *target;
    void            *replacement;
    void            *original;   /* first original we find */
    int              count;
};

/* Check if the library providing cur_val matches the pattern.
 * Uses dladdr to resolve which .so the function lives in. */
static int provider_matches(void *cur_val, const char *pattern)
{
    if (!pattern) return 1;  /* NULL means match any */

    Dl_info info;
    if (!dladdr(cur_val, &info) || !info.dli_fname)
        return 0;

    return strstr(info.dli_fname, pattern) != NULL;
}

static int replace_cb(const char *sym, const char *lib,
                      void **got_slot, void *cur_val, void *user)
{
    (void)lib;
    struct replace_ctx *ctx = user;

    if (strcmp(sym, ctx->target->sym) != 0) return 0;
    if (!provider_matches(cur_val, ctx->target->lib)) return 0;

    if (ctx->count == 0)
        ctx->original = cur_val;

    if (patch_got_slot(got_slot, ctx->replacement) == 0)
        ctx->count++;

    return 0;  /* continue to patch all matching entries */
}

void *dlreplace(const char *target, void *replacement)
{
    if (!ldx_initialized) ldx_init();

    parsed_target_t pt;
    parse_target(target, &pt);

    struct replace_ctx ctx = {
        .target = &pt,
        .replacement = replacement,
        .original = NULL,
        .count = 0,
    };

    ldx_walk_got(replace_cb, &ctx);

    if (ctx.count > 0)
        fprintf(stderr, "ldx: replaced %s in %d GOT slot(s)\n", target, ctx.count);
    else
        fprintf(stderr, "ldx: warning: no GOT entries found for '%s'\n", target);

    free_target(&pt);
    return ctx.original;
}

/* ---------- dlreplaceq ---------- */

struct replaceq_ctx {
    const char    *pattern;
    dlreplaceq_cb  callback;
    int            count;
};

static int replaceq_cb(const char *sym, const char *lib,
                       void **got_slot, void *cur_val, void *user)
{
    struct replaceq_ctx *ctx = user;

    if (fnmatch(ctx->pattern, sym, 0) != 0) return 0;

    void *replacement = ctx->callback(sym, lib, cur_val);
    if (replacement && replacement != cur_val) {
        if (patch_got_slot(got_slot, replacement) == 0)
            ctx->count++;
    }
    return 0;
}

int dlreplaceq(const char *pattern, dlreplaceq_cb callback)
{
    if (!ldx_initialized) ldx_init();

    struct replaceq_ctx ctx = {
        .pattern = pattern,
        .callback = callback,
        .count = 0,
    };

    ldx_walk_got(replaceq_cb, &ctx);
    return ctx.count;
}

/* ---------- hooks / instrumentation ---------- */

#define MAX_HOOKS 256

typedef struct {
    void       **got_slot;
    void        *original;       /* original function pointer */
    void        *trampoline;     /* generated trampoline code */
    ldx_hook_fn  hook;
    char         sym[128];
    char         lib[256];
    /* profiler stats */
    unsigned long call_count;
    double        total_time;
    double        min_time;
    double        max_time;
} hook_entry_t;

static hook_entry_t hooks[MAX_HOOKS];
static int          hook_count = 0;

/* Trampoline memory — we mmap a single RWX page and carve trampolines from it. */
static unsigned char *tramp_page = NULL;
static size_t         tramp_offset = 0;

static double now_monotonic(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* The C-level shim that every trampoline calls.
 * It's called TWICE per invocation: once on entry, once on exit.
 * On entry: calls hook with is_exit=0, returns original function pointer.
 * On exit:  calls hook with is_exit=1, returns nothing useful.
 *
 * But since the trampoline must handle arbitrary calling conventions,
 * we use a different approach: the trampoline saves all arg registers,
 * calls the dispatcher, restores registers, calls original, then
 * saves return value, calls dispatcher again, restores return value.
 */

/* Called by trampoline on entry.  hook_idx is baked into the trampoline. */
static void hook_entry(int hook_idx)
{
    hook_entry_t *e = &hooks[hook_idx];
    double ts = now_monotonic();
    unsigned long tid = (unsigned long)pthread_self();

    /* Store entry timestamp in a thread-local slot keyed by hook_idx.
     * Simple approach: use the hook entry directly (not thread-safe for
     * the timestamp, but call_count is fine with atomics).
     * For now, store in a thread-local. */
    e->hook(e->sym, e->lib, 0, tid, ts);
}

/* Called by trampoline on exit. */
static void hook_exit(int hook_idx)
{
    hook_entry_t *e = &hooks[hook_idx];
    double ts = now_monotonic();
    unsigned long tid = (unsigned long)pthread_self();
    e->hook(e->sym, e->lib, 1, tid, ts);
}

#if defined(__x86_64__)

/*
 * x86_64 trampoline layout:
 *
 * We generate a small code stub that:
 * 1. Saves all argument registers (rdi,rsi,rdx,rcx,r8,r9) + xmm0-7 + rax
 * 2. Calls hook_entry(idx) with idx in %edi
 * 3. Restores all argument registers
 * 4. Calls the original function
 * 5. Saves return registers (rax, rdx, xmm0)
 * 6. Calls hook_exit(idx)
 * 7. Restores return registers
 * 8. Returns
 *
 * The trampoline is ~200 bytes.  We need a sub-call to the original
 * to get a proper stack frame.  The key constraint: we must preserve
 * the 16-byte stack alignment required by the ABI.
 */

static void emit(unsigned char **p, const void *bytes, size_t n)
{
    memcpy(*p, bytes, n);
    *p += n;
}

static void emit_byte(unsigned char **p, unsigned char b)
{
    **p = b;
    (*p)++;
}

/* Emit: mov $imm64, %rax; call *%rax */
static void emit_call_abs(unsigned char **p, void *target)
{
    /* movabs $imm64, %rax */
    emit_byte(p, 0x48); emit_byte(p, 0xb8);
    uint64_t addr = (uint64_t)target;
    emit(p, &addr, 8);
    /* call *%rax */
    emit_byte(p, 0xff); emit_byte(p, 0xd0);
}

/* Emit: mov $imm32, %edi */
static void emit_mov_edi_imm(unsigned char **p, int32_t val)
{
    emit_byte(p, 0xbf);
    emit(p, &val, 4);
}

static void *generate_trampoline(int hook_idx, void *original)
{
    if (!tramp_page) {
        tramp_page = mmap(NULL, page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (tramp_page == MAP_FAILED) {
            perror("ldx: mmap trampoline");
            return NULL;
        }
    }

    /* Each trampoline is at most 512 bytes — generous. */
    if (tramp_offset + 512 > (size_t)page_size) {
        /* Allocate another page. */
        tramp_page = mmap(NULL, page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (tramp_page == MAP_FAILED) {
            perror("ldx: mmap trampoline");
            return NULL;
        }
        tramp_offset = 0;
    }

    unsigned char *base = tramp_page + tramp_offset;
    unsigned char *p = base;

    /*
     * Strategy: Instead of saving/restoring all 14 registers (6 GPR + 8 XMM)
     * in generated machine code (complex, error-prone), we use a simpler
     * approach: call a C wrapper that takes the original function pointer
     * and hook index, and does the save/call/restore in inline asm.
     *
     * Actually, the simplest correct approach: the trampoline just calls
     * a C dispatch function that uses the hook table.  The dispatch
     * function is a variadic-args forwarder... which doesn't work in C.
     *
     * Correct approach: save all arg regs in asm, call hook_entry,
     * restore all arg regs, call original, save retval regs, call
     * hook_exit, restore retval regs, ret.
     */

    /* push rbp; mov rsp, rbp — frame pointer for alignment tracking */
    emit_byte(&p, 0x55);                               /* push %rbp */
    emit_byte(&p, 0x48); emit_byte(&p, 0x89);
    emit_byte(&p, 0xe5);                               /* mov %rsp,%rbp */

    /* Save integer argument registers */
    emit_byte(&p, 0x57);                               /* push %rdi */
    emit_byte(&p, 0x56);                               /* push %rsi */
    emit_byte(&p, 0x52);                               /* push %rdx */
    emit_byte(&p, 0x51);                               /* push %rcx */
    emit_byte(&p, 0x41); emit_byte(&p, 0x50);          /* push %r8 */
    emit_byte(&p, 0x41); emit_byte(&p, 0x51);          /* push %r9 */
    emit_byte(&p, 0x50);                               /* push %rax (varargs count) */

    /* Save xmm0-7: sub $128,%rsp then movdqu each */
    /* sub $128, %rsp */
    emit_byte(&p, 0x48); emit_byte(&p, 0x81);
    emit_byte(&p, 0xec);
    int32_t xmm_space = 128;
    emit(&p, &xmm_space, 4);

    for (int i = 0; i < 8; i++) {
        /* movdqu %xmmN, i*16(%rsp)
         * F3 0F 7F ModRM SIB disp8
         * ModRM = 01 reg 100 = 0x44 | (reg << 3)
         * SIB   = 00 100 100 = 0x24 (base=rsp, no index) */
        emit_byte(&p, 0xf3); emit_byte(&p, 0x0f);
        emit_byte(&p, 0x7f); emit_byte(&p, 0x44 | (i << 3));
        emit_byte(&p, 0x24); emit_byte(&p, (unsigned char)(i * 16));
    }

    /* Align stack to 16 bytes before call.
     * We pushed rbp + 7 regs = 8 pushes (64 bytes) + sub 128 = 192.
     * rbp was 16-aligned (ABI), 192 is divisible by 16, so we're good.
     * Actually: caller's rsp was 16-aligned before the call instruction
     * pushed the return address (8 bytes), so on entry rsp ≡ 8 (mod 16).
     * push rbp: rsp ≡ 0 (mod 16). 7 pushes: rsp ≡ 8 (mod 16).
     * sub 128: rsp ≡ 8-128 ≡ 8 (mod 16). Need one more push or sub 8. */
    emit_byte(&p, 0x48); emit_byte(&p, 0x83);
    emit_byte(&p, 0xec); emit_byte(&p, 0x08);          /* sub $8,%rsp */

    /* Call hook_entry(hook_idx) */
    emit_mov_edi_imm(&p, hook_idx);
    emit_call_abs(&p, (void *)hook_entry);

    /* Undo alignment pad */
    emit_byte(&p, 0x48); emit_byte(&p, 0x83);
    emit_byte(&p, 0xc4); emit_byte(&p, 0x08);          /* add $8,%rsp */

    /* Restore xmm0-7 */
    for (int i = 0; i < 8; i++) {
        /* movdqu i*16(%rsp), %xmmN */
        emit_byte(&p, 0xf3); emit_byte(&p, 0x0f);
        emit_byte(&p, 0x6f); emit_byte(&p, 0x44 | (i << 3));
        emit_byte(&p, 0x24); emit_byte(&p, (unsigned char)(i * 16));
    }
    /* add $128, %rsp */
    emit_byte(&p, 0x48); emit_byte(&p, 0x81);
    emit_byte(&p, 0xc4);
    emit(&p, &xmm_space, 4);

    /* Restore integer argument registers (reverse order) */
    emit_byte(&p, 0x58);                               /* pop %rax */
    emit_byte(&p, 0x41); emit_byte(&p, 0x59);          /* pop %r9 */
    emit_byte(&p, 0x41); emit_byte(&p, 0x58);          /* pop %r8 */
    emit_byte(&p, 0x59);                               /* pop %rcx */
    emit_byte(&p, 0x5a);                               /* pop %rdx */
    emit_byte(&p, 0x5e);                               /* pop %rsi */
    emit_byte(&p, 0x5f);                               /* pop %rdi */

    /* Restore rbp, but we need it for the frame. Actually, we need to
     * call the original with the exact same stack layout the caller had.
     * pop rbp now, then call original. */
    emit_byte(&p, 0x5d);                               /* pop %rbp */

    /* Call original function.
     * We use call (not jmp) because we need to run hook_exit after.
     * movabs original, %r11; call *%r11 */
    emit_byte(&p, 0x49); emit_byte(&p, 0xbb);          /* movabs $imm64, %r11 */
    uint64_t orig_addr = (uint64_t)original;
    emit(&p, &orig_addr, 8);
    emit_byte(&p, 0x41); emit_byte(&p, 0xff);
    emit_byte(&p, 0xd3);                               /* call *%r11 */

    /* Save return value registers: rax, rdx, xmm0, xmm1 */
    emit_byte(&p, 0x50);                               /* push %rax */
    emit_byte(&p, 0x52);                               /* push %rdx */
    /* sub $32,%rsp for xmm0,xmm1 */
    emit_byte(&p, 0x48); emit_byte(&p, 0x83);
    emit_byte(&p, 0xec); emit_byte(&p, 0x20);
    /* movdqu %xmm0, (%rsp) */
    emit_byte(&p, 0xf3); emit_byte(&p, 0x0f);
    emit_byte(&p, 0x7f); emit_byte(&p, 0x04);
    emit_byte(&p, 0x24);
    /* movdqu %xmm1, 16(%rsp) */
    emit_byte(&p, 0xf3); emit_byte(&p, 0x0f);
    emit_byte(&p, 0x7f); emit_byte(&p, 0x4c);
    emit_byte(&p, 0x24); emit_byte(&p, 0x10);

    /* Align for call: pushed 2 regs (16) + sub 32 = 48 from post-call rsp.
     * Post-call rsp ≡ 0 mod 16 (ABI). 48 mod 16 = 0. Good. */

    /* Call hook_exit(hook_idx) */
    emit_mov_edi_imm(&p, hook_idx);
    emit_call_abs(&p, (void *)hook_exit);

    /* Restore return registers */
    /* movdqu 16(%rsp), %xmm1 */
    emit_byte(&p, 0xf3); emit_byte(&p, 0x0f);
    emit_byte(&p, 0x6f); emit_byte(&p, 0x4c);
    emit_byte(&p, 0x24); emit_byte(&p, 0x10);
    /* movdqu (%rsp), %xmm0 */
    emit_byte(&p, 0xf3); emit_byte(&p, 0x0f);
    emit_byte(&p, 0x6f); emit_byte(&p, 0x04);
    emit_byte(&p, 0x24);
    /* add $32,%rsp */
    emit_byte(&p, 0x48); emit_byte(&p, 0x83);
    emit_byte(&p, 0xc4); emit_byte(&p, 0x20);
    emit_byte(&p, 0x5a);                               /* pop %rdx */
    emit_byte(&p, 0x58);                               /* pop %rax */

    /* ret */
    emit_byte(&p, 0xc3);

    size_t tramp_size = (size_t)(p - base);
    tramp_offset += (tramp_size + 15) & ~15u;  /* align next trampoline */

    return base;
}

#else
/* Non-x86_64: stub that prints a warning. */
static void *generate_trampoline(int hook_idx, void *original)
{
    (void)hook_idx; (void)original;
    fprintf(stderr, "ldx: trampoline generation not supported on this architecture\n");
    return NULL;
}
#endif /* __x86_64__ */

struct hook_add_ctx {
    parsed_target_t *target;
    ldx_hook_fn      hook;
    int              found;
};

static int hook_add_cb(const char *sym, const char *lib,
                       void **got_slot, void *cur_val, void *user)
{
    struct hook_add_ctx *ctx = user;

    if (strcmp(sym, ctx->target->sym) != 0) return 0;
    if (!provider_matches(cur_val, ctx->target->lib)) return 0;

    if (hook_count >= MAX_HOOKS) {
        fprintf(stderr, "ldx: hook table full\n");
        return 1;
    }

    int idx = hook_count++;
    hook_entry_t *e = &hooks[idx];
    e->got_slot = got_slot;
    e->original = cur_val;
    e->hook = ctx->hook;
    e->call_count = 0;
    e->total_time = 0;
    e->min_time = 1e30;
    e->max_time = 0;
    snprintf(e->sym, sizeof(e->sym), "%s", sym);
    snprintf(e->lib, sizeof(e->lib), "%s", lib);

    /* Generate trampoline and patch GOT. */
    e->trampoline = generate_trampoline(idx, cur_val);
    if (!e->trampoline) {
        hook_count--;
        return 0;
    }

    if (patch_got_slot(got_slot, e->trampoline) != 0) {
        hook_count--;
        return 0;
    }

    fprintf(stderr, "ldx: hooked %s (trampoline at %p)\n", sym, e->trampoline);
    ctx->found = 1;
    return 0;
}

int ldx_add_hook(const char *target, ldx_hook_fn hook)
{
    if (!ldx_initialized) ldx_init();

    parsed_target_t pt;
    parse_target(target, &pt);

    struct hook_add_ctx ctx = { .target = &pt, .hook = hook, .found = 0 };
    ldx_walk_got(hook_add_cb, &ctx);

    free_target(&pt);
    return ctx.found ? 0 : -1;
}

/* ---------- profiler (Phase 1.4) ---------- */

/* Thread-local storage for entry timestamps, keyed by hook index. */
static __thread double prof_entry_ts[MAX_HOOKS];

static void prof_hook(const char *sym, const char *lib,
                      int is_exit, unsigned long thread_id,
                      double timestamp)
{
    (void)sym; (void)lib; (void)thread_id;

    /* Find hook index by symbol name — we baked it into the trampoline,
     * but the hook callback doesn't receive it.  Search by sym+lib. */
    int idx = -1;
    for (int i = 0; i < hook_count; i++) {
        if (strcmp(hooks[i].sym, sym) == 0 &&
            strcmp(hooks[i].lib, lib) == 0) {
            idx = i;
            break;
        }
    }
    if (idx < 0) return;

    if (!is_exit) {
        prof_entry_ts[idx] = timestamp;
    } else {
        double elapsed = timestamp - prof_entry_ts[idx];
        hook_entry_t *e = &hooks[idx];
        __sync_fetch_and_add(&e->call_count, 1);
        /* These aren't atomic but good enough for profiling. */
        e->total_time += elapsed;
        if (elapsed < e->min_time) e->min_time = elapsed;
        if (elapsed > e->max_time) e->max_time = elapsed;
    }
}

int ldx_prof_add(const char *target)
{
    return ldx_add_hook(target, prof_hook);
}

void ldx_prof_report(void)
{
    fprintf(stderr, "\n=== ldx profiler report ===\n");
    fprintf(stderr, "%-30s %10s %12s %12s %12s %12s\n",
            "Symbol", "Calls", "Total(ms)", "Avg(us)", "Min(us)", "Max(us)");
    fprintf(stderr, "%-30s %10s %12s %12s %12s %12s\n",
            "------", "-----", "---------", "-------", "-------", "-------");

    for (int i = 0; i < hook_count; i++) {
        hook_entry_t *e = &hooks[i];
        if (e->call_count == 0) continue;

        double avg_us = (e->total_time / e->call_count) * 1e6;
        fprintf(stderr, "%-30s %10lu %12.3f %12.3f %12.3f %12.3f\n",
                e->sym,
                e->call_count,
                e->total_time * 1e3,
                avg_us,
                e->min_time * 1e6,
                e->max_time * 1e6);
    }
    fprintf(stderr, "===========================\n\n");
}

int ldx_prof_get(ldx_prof_entry_t *entries, int max_entries)
{
    int count = 0;
    for (int i = 0; i < hook_count && count < max_entries; i++) {
        if (hooks[i].call_count == 0) continue;
        if (entries) {
            entries[count].sym = hooks[i].sym;
            entries[count].lib = hooks[i].lib;
            entries[count].call_count = hooks[i].call_count;
            entries[count].total_time = hooks[i].total_time;
            entries[count].min_time = hooks[i].min_time;
            entries[count].max_time = hooks[i].max_time;
        }
        count++;
    }
    return count;
}

void ldx_prof_reset(void)
{
    for (int i = 0; i < hook_count; i++) {
        hooks[i].call_count = 0;
        hooks[i].total_time = 0;
        hooks[i].min_time = 1e30;
        hooks[i].max_time = 0;
    }
}

/* ---------- init ---------- */

void ldx_init(void)
{
    if (ldx_initialized) return;
    ldx_initialized = 1;
    page_size = sysconf(_SC_PAGESIZE);
    fprintf(stderr, "ldx: initialized (page_size=%ld)\n", page_size);
}

/* Auto-init when loaded via LD_PRELOAD. */
__attribute__((constructor))
static void ldx_auto_init(void)
{
    ldx_init();
}
