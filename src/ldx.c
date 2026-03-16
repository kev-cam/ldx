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

/* Simple hook table — maps GOT slot address to hook info. */
#define MAX_HOOKS 256

typedef struct {
    void      **got_slot;
    void       *original;
    ldx_hook_fn hook;
    char        sym[128];
    char        lib[256];
} hook_entry_t;

static hook_entry_t hooks[MAX_HOOKS];
static int          hook_count = 0;

/* We generate a unique trampoline per hook slot.  For now, use a
 * dispatch approach: each hooked call goes through a generic shim
 * that looks up the hook entry by return-address / slot.
 *
 * For Phase 1, we use a simpler approach: store original + hook in
 * the table and provide a macro/function for the Python layer to
 * generate typed wrapper functions.  Direct GOT-level trampolines
 * need runtime code generation (mmap + PROT_EXEC) which we'll add
 * in the next iteration.
 */

static double now_monotonic(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

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

    hook_entry_t *e = &hooks[hook_count++];
    e->got_slot = got_slot;
    e->original = cur_val;
    e->hook = ctx->hook;
    snprintf(e->sym, sizeof(e->sym), "%s", sym);
    snprintf(e->lib, sizeof(e->lib), "%s", lib);

    ctx->found = 1;
    /* Don't patch GOT here — the caller generates a typed trampoline
     * and patches the slot to point to it.  We just record the hook. */
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
