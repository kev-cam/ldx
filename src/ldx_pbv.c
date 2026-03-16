#define _GNU_SOURCE
#include "ldx_pbv.h"
#include "ldx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

/* Private strlen — doesn't go through PLT/GOT, so it's safe to use
 * inside PbV shims that may have intercepted the real strlen. */
static size_t ldx_strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

/* ---------- signature API ---------- */

ldx_sig_t *ldx_sig_create(const char *name, const char *target)
{
    ldx_sig_t *sig = calloc(1, sizeof(ldx_sig_t));
    if (!sig) return NULL;
    snprintf(sig->name, sizeof(sig->name), "%s", name);
    snprintf(sig->target, sizeof(sig->target), "%s", target);
    return sig;
}

int ldx_sig_add_arg(ldx_sig_t *sig, const char *name,
                    int direction, int type, size_t size)
{
    if (sig->nargs >= LDX_MAX_ARGS) return -1;
    ldx_arg_desc_t *a = &sig->args[sig->nargs++];
    a->name = name;  /* caller owns the string */
    a->direction = direction;
    a->type = type;
    a->size = size;
    return 0;
}

void ldx_sig_set_return(ldx_sig_t *sig, int type, size_t size)
{
    sig->ret_type = type;
    sig->ret_size = size;
}

void ldx_sig_free(ldx_sig_t *sig)
{
    free(sig);
}

/* ---------- type sizes ---------- */

static size_t type_default_size(int type)
{
    switch (type) {
    case LDX_TYPE_INT:    return sizeof(int);
    case LDX_TYPE_UINT:   return sizeof(unsigned int);
    case LDX_TYPE_LONG:   return sizeof(long);
    case LDX_TYPE_ULONG:  return sizeof(unsigned long);
    case LDX_TYPE_FLOAT:  return sizeof(float);
    case LDX_TYPE_DOUBLE: return sizeof(double);
    case LDX_TYPE_PTR:    return sizeof(void *);
    default:              return 0;
    }
}

static size_t arg_data_size(const ldx_arg_desc_t *a, uint64_t reg_val)
{
    if (a->type == LDX_TYPE_STRING) {
        /* For strings, we need to read the actual string to know length. */
        const char *s = (const char *)(uintptr_t)reg_val;
        return s ? ldx_strlen(s) + 1 : 0;
    }
    if (a->size > 0) return a->size;
    return type_default_size(a->type);
}

/* ---------- serialization ---------- */

ldx_packet_t *ldx_pbv_serialize(const ldx_sig_t *sig, uint64_t reg_args[],
                                int capture_output)
{
    /* First pass: compute total payload size. */
    size_t payload_size = 0;
    for (int i = 0; i < sig->nargs; i++) {
        const ldx_arg_desc_t *a = &sig->args[i];

        int want = 0;
        if (!capture_output && (a->direction == LDX_ARG_PTR_IN ||
                                a->direction == LDX_ARG_PTR_INOUT))
            want = 1;
        if (capture_output && (a->direction == LDX_ARG_PTR_OUT ||
                               a->direction == LDX_ARG_PTR_INOUT))
            want = 1;
        if (a->direction == LDX_ARG_VAL && !capture_output)
            want = 1;

        if (!want) continue;

        size_t dsz;
        if (a->direction == LDX_ARG_VAL)
            dsz = arg_data_size(a, reg_args[i]);
        else
            dsz = arg_data_size(a, reg_args[i]);

        payload_size += sizeof(ldx_arg_header_t) + dsz;
    }

    /* Allocate packet. */
    ldx_packet_t *pkt = malloc(sizeof(ldx_packet_t) + payload_size);
    if (!pkt) return NULL;

    snprintf(pkt->func_name, sizeof(pkt->func_name), "%s", sig->name);
    pkt->nargs = sig->nargs;
    pkt->total_size = (uint32_t)payload_size;

    /* Second pass: fill payload. */
    unsigned char *p = pkt->payload;
    for (int i = 0; i < sig->nargs; i++) {
        const ldx_arg_desc_t *a = &sig->args[i];

        int want = 0;
        if (!capture_output && (a->direction == LDX_ARG_PTR_IN ||
                                a->direction == LDX_ARG_PTR_INOUT))
            want = 1;
        if (capture_output && (a->direction == LDX_ARG_PTR_OUT ||
                               a->direction == LDX_ARG_PTR_INOUT))
            want = 1;
        if (a->direction == LDX_ARG_VAL && !capture_output)
            want = 1;

        if (!want) continue;

        size_t dsz;
        if (a->direction == LDX_ARG_VAL)
            dsz = arg_data_size(a, reg_args[i]);
        else
            dsz = arg_data_size(a, reg_args[i]);

        ldx_arg_header_t *hdr = (ldx_arg_header_t *)p;
        hdr->arg_index = i;
        hdr->direction = a->direction;
        hdr->type = a->type;
        hdr->data_size = (uint32_t)dsz;
        p += sizeof(ldx_arg_header_t);

        if (a->direction == LDX_ARG_VAL) {
            /* Copy the register value directly. */
            memcpy(p, &reg_args[i], dsz <= 8 ? dsz : 8);
        } else {
            /* Dereference the pointer and copy the data. */
            void *ptr = (void *)(uintptr_t)reg_args[i];
            if (ptr && dsz > 0)
                memcpy(p, ptr, dsz);
        }
        p += dsz;
    }

    return pkt;
}

/* ---------- deserialization ---------- */

int ldx_pbv_deserialize(const ldx_sig_t *sig, const ldx_packet_t *pkt,
                        ldx_deser_ctx_t *ctx)
{
    memset(ctx, 0, sizeof(*ctx));

    /* Start with zero args — VAL args get their value directly,
     * PTR args get a pointer to an allocated buffer. */
    const unsigned char *p = pkt->payload;
    const unsigned char *end = p + pkt->total_size;

    while (p < end) {
        const ldx_arg_header_t *hdr = (const ldx_arg_header_t *)p;
        p += sizeof(ldx_arg_header_t);
        int idx = hdr->arg_index;

        if (idx < 0 || idx >= sig->nargs) {
            p += hdr->data_size;
            continue;
        }

        const ldx_arg_desc_t *a = &sig->args[idx];

        if (a->direction == LDX_ARG_VAL) {
            /* Reconstruct the register value. */
            ctx->reg_args[idx] = 0;
            memcpy(&ctx->reg_args[idx], p, hdr->data_size <= 8 ? hdr->data_size : 8);
        } else {
            /* Allocate a buffer and copy the data into it.
             * Store the pointer as the register value. */
            void *buf = malloc(hdr->data_size);
            if (!buf) return -1;
            memcpy(buf, p, hdr->data_size);
            ctx->reg_args[idx] = (uint64_t)(uintptr_t)buf;
            ctx->alloc_ptrs[ctx->nalloc++] = buf;
        }

        p += hdr->data_size;
    }

    return 0;
}

void ldx_pbv_deser_free(ldx_deser_ctx_t *ctx)
{
    for (int i = 0; i < ctx->nalloc; i++)
        free(ctx->alloc_ptrs[i]);
    ctx->nalloc = 0;
}

/* ---------- packet dump ---------- */

static const char *type_name(int type)
{
    switch (type) {
    case LDX_TYPE_INT:    return "int";
    case LDX_TYPE_UINT:   return "uint";
    case LDX_TYPE_LONG:   return "long";
    case LDX_TYPE_ULONG:  return "ulong";
    case LDX_TYPE_FLOAT:  return "float";
    case LDX_TYPE_DOUBLE: return "double";
    case LDX_TYPE_PTR:    return "ptr";
    case LDX_TYPE_STRUCT: return "struct";
    case LDX_TYPE_STRING: return "string";
    default:              return "?";
    }
}

static const char *dir_name(int dir)
{
    switch (dir) {
    case LDX_ARG_VAL:       return "val";
    case LDX_ARG_PTR_IN:    return "ptr_in";
    case LDX_ARG_PTR_OUT:   return "ptr_out";
    case LDX_ARG_PTR_INOUT: return "ptr_inout";
    default:                 return "?";
    }
}

void ldx_packet_dump(const ldx_sig_t *sig, const ldx_packet_t *pkt)
{
    fprintf(stderr, "=== PbV packet: %s (%u bytes) ===\n",
            pkt->func_name, pkt->total_size);

    const unsigned char *p = pkt->payload;
    const unsigned char *end = p + pkt->total_size;

    while (p < end) {
        const ldx_arg_header_t *hdr = (const ldx_arg_header_t *)p;
        p += sizeof(ldx_arg_header_t);

        int idx = hdr->arg_index;
        const char *aname = (idx >= 0 && idx < sig->nargs) ?
                            sig->args[idx].name : "?";

        fprintf(stderr, "  arg[%d] \"%s\" %s %s %u bytes: ",
                idx, aname, dir_name(hdr->direction),
                type_name(hdr->type), hdr->data_size);

        /* Print value based on type. */
        if (hdr->data_size == 0) {
            fprintf(stderr, "(empty)");
        } else if (hdr->type == LDX_TYPE_INT && hdr->data_size == sizeof(int)) {
            int v; memcpy(&v, p, sizeof(v));
            fprintf(stderr, "%d", v);
        } else if (hdr->type == LDX_TYPE_DOUBLE && hdr->data_size == sizeof(double)) {
            double v; memcpy(&v, p, sizeof(v));
            fprintf(stderr, "%f", v);
        } else if (hdr->type == LDX_TYPE_FLOAT && hdr->data_size == sizeof(float)) {
            float v; memcpy(&v, p, sizeof(v));
            fprintf(stderr, "%f", v);
        } else if (hdr->type == LDX_TYPE_LONG && hdr->data_size == sizeof(long)) {
            long v; memcpy(&v, p, sizeof(v));
            fprintf(stderr, "%ld", v);
        } else if (hdr->type == LDX_TYPE_STRING) {
            fprintf(stderr, "\"%.*s\"", (int)hdr->data_size, (const char *)p);
        } else if (hdr->type == LDX_TYPE_STRUCT) {
            /* Hex dump first 32 bytes. */
            size_t show = hdr->data_size < 32 ? hdr->data_size : 32;
            for (size_t i = 0; i < show; i++)
                fprintf(stderr, "%02x ", p[i]);
            if (hdr->data_size > 32)
                fprintf(stderr, "...");
        } else {
            uint64_t v = 0;
            memcpy(&v, p, hdr->data_size <= 8 ? hdr->data_size : 8);
            fprintf(stderr, "0x%lx", (unsigned long)v);
        }
        fprintf(stderr, "\n");

        p += hdr->data_size;
    }
    fprintf(stderr, "=================================\n");
}

/* ---------- PbV shim ---------- */

/*
 * The PbV shim reuses ldx's hook mechanism.  When the target function
 * is called, the hook fires.  On entry, we capture register values,
 * serialize the input args, and invoke the callback.  On exit, we
 * serialize the output args and invoke the callback again.
 *
 * To pass register values to the serializer, we use thread-local storage
 * keyed by the signature pointer.
 */

#define MAX_PBV_SHIMS 64

typedef struct {
    ldx_sig_t          *sig;
    ldx_pbv_callback_t  callback;
    void               *user;
    void               *original;    /* original function pointer */
} pbv_shim_t;

static pbv_shim_t pbv_shims[MAX_PBV_SHIMS];
static int pbv_shim_count = 0;

/* Thread-local: register snapshot from the trampoline's entry hook.
 * The hook_entry function is called with a hook_idx — we use that
 * to find the pbv_shim.  But the hook callback only gets sym/lib strings,
 * not the raw registers.
 *
 * Approach: We use ldx_add_hook which installs a trampoline.  The trampoline
 * saves registers, calls hook_entry, restores, calls original, calls hook_exit.
 * But our hook callback doesn't have access to the register values.
 *
 * Better approach: Use dlreplace to install our OWN trampoline that captures
 * registers, serializes, calls original, serializes output.  We already have
 * the trampoline generation code — let's extend it.
 *
 * Actually, the simplest correct approach: generate a new type of trampoline
 * specifically for PbV that passes register values to a C dispatcher.
 */

/* PbV dispatcher — called from the trampoline with saved register values.
 * shim_idx is baked into the trampoline.
 * regs points to the saved integer registers [rdi, rsi, rdx, rcx, r8, r9].
 */
static void pbv_dispatch_entry(int shim_idx, uint64_t *regs)
{
    if (shim_idx < 0 || shim_idx >= pbv_shim_count) return;
    pbv_shim_t *shim = &pbv_shims[shim_idx];

    ldx_packet_t *pkt = ldx_pbv_serialize(shim->sig, regs, 0);
    if (pkt && shim->callback)
        shim->callback(shim->sig, pkt, shim->user);
    free(pkt);
}

static void pbv_dispatch_exit(int shim_idx, uint64_t *regs)
{
    if (shim_idx < 0 || shim_idx >= pbv_shim_count) return;
    pbv_shim_t *shim = &pbv_shims[shim_idx];

    /* Check if any args are PTR_OUT or PTR_INOUT. */
    int has_output = 0;
    for (int i = 0; i < shim->sig->nargs; i++) {
        if (shim->sig->args[i].direction == LDX_ARG_PTR_OUT ||
            shim->sig->args[i].direction == LDX_ARG_PTR_INOUT) {
            has_output = 1;
            break;
        }
    }
    if (!has_output) return;

    ldx_packet_t *pkt = ldx_pbv_serialize(shim->sig, regs, 1);
    if (pkt && shim->callback)
        shim->callback(shim->sig, pkt, shim->user);
    free(pkt);
}

#if defined(__x86_64__)

extern long page_size_for_pbv(void);  /* we'll get this from ldx.c */

static void emit_byte_pbv(unsigned char **p, unsigned char b)
{
    **p = b; (*p)++;
}

static void emit_pbv(unsigned char **p, const void *bytes, size_t n)
{
    memcpy(*p, bytes, n);
    *p += n;
}

static void emit_call_abs_pbv(unsigned char **p, void *target)
{
    emit_byte_pbv(p, 0x48); emit_byte_pbv(p, 0xb8);
    uint64_t addr = (uint64_t)target;
    emit_pbv(p, &addr, 8);
    emit_byte_pbv(p, 0xff); emit_byte_pbv(p, 0xd0);
}

/*
 * PbV trampoline:
 * 1. Save all arg registers to a local array on the stack
 * 2. Call pbv_dispatch_entry(shim_idx, &saved_regs)
 * 3. Restore all arg registers
 * 4. Call original function
 * 5. Save return value + re-save arg registers (for output capture)
 * 6. Call pbv_dispatch_exit(shim_idx, &saved_regs)
 * 7. Restore return value, return
 */
static void *generate_pbv_trampoline(int shim_idx, void *original)
{
    long psz = sysconf(_SC_PAGESIZE);
    unsigned char *page = mmap(NULL, psz, PROT_READ | PROT_WRITE | PROT_EXEC,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED) {
        perror("ldx: mmap pbv trampoline");
        return NULL;
    }

    unsigned char *base = page;
    unsigned char *p = base;

    /* push rbp; mov rsp, rbp */
    emit_byte_pbv(&p, 0x55);
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0xe5);

    /* Allocate space for saved regs: 6 * 8 = 48 bytes at rbp-48.
     * Also save xmm0-7 for floating-point args: 8 * 16 = 128 bytes at rbp-176.
     * Total: sub $176, %rsp  (must keep 16-byte aligned)
     * After push rbp: rsp is 16-aligned.
     * sub 176: 176 = 11*16, so rsp stays 16-aligned. */
    /* sub $192, %rsp  (192 = 48 + 128 + 16 for alignment pad) */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x81);
    emit_byte_pbv(&p, 0xec);
    int32_t frame = 192;
    emit_pbv(&p, &frame, 4);

    /* Save integer arg registers into array at rsp+0..rsp+47.
     * Layout: [rdi, rsi, rdx, rcx, r8, r9] */
    /* mov %rdi, 0(%rsp) */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x3c); emit_byte_pbv(&p, 0x24);
    /* mov %rsi, 8(%rsp) */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x74); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x08);
    /* mov %rdx, 16(%rsp) */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x54); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x10);
    /* mov %rcx, 24(%rsp) */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x18);
    /* mov %r8, 32(%rsp) */
    emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x44); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x20);
    /* mov %r9, 40(%rsp) */
    emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x28);

    /* Save xmm0-7 at rsp+48..rsp+175 */
    for (int i = 0; i < 8; i++) {
        /* movdqu %xmmN, (48+i*16)(%rsp) */
        emit_byte_pbv(&p, 0xf3); emit_byte_pbv(&p, 0x0f);
        emit_byte_pbv(&p, 0x7f);
        uint8_t disp = 48 + i * 16;
        if (disp < 128) {
            emit_byte_pbv(&p, 0x44 | (i << 3));
            emit_byte_pbv(&p, 0x24);
            emit_byte_pbv(&p, disp);
        } else {
            emit_byte_pbv(&p, 0x84 | (i << 3));
            emit_byte_pbv(&p, 0x24);
            int32_t d32 = disp;
            emit_pbv(&p, &d32, 4);
        }
    }

    /* Save rax (varargs count) — push onto the extra pad space at rsp+176 */
    /* mov %rax, 176(%rsp) */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0x84);
    emit_byte_pbv(&p, 0x24);
    int32_t rax_off = 176;
    emit_pbv(&p, &rax_off, 4);

    /* Call pbv_dispatch_entry(shim_idx, regs_array_ptr)
     * %edi = shim_idx, %rsi = rsp (pointer to saved regs array)
     * Stack is 16-aligned here (push rbp + sub 192 = 200 total, but
     * on entry rsp was 8-aligned due to call instruction, so:
     * push rbp: rsp mod 16 = 0. sub 192: still 0. Good.) */
    /* mov $shim_idx, %edi */
    emit_byte_pbv(&p, 0xbf);
    emit_pbv(&p, &shim_idx, 4);
    /* lea (%rsp), %rsi */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x89); emit_byte_pbv(&p, 0xe6);

    emit_call_abs_pbv(&p, (void *)pbv_dispatch_entry);

    /* Restore rax */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x84);
    emit_byte_pbv(&p, 0x24);
    emit_pbv(&p, &rax_off, 4);

    /* Restore xmm0-7 */
    for (int i = 0; i < 8; i++) {
        emit_byte_pbv(&p, 0xf3); emit_byte_pbv(&p, 0x0f);
        emit_byte_pbv(&p, 0x6f);
        uint8_t disp = 48 + i * 16;
        if (disp < 128) {
            emit_byte_pbv(&p, 0x44 | (i << 3));
            emit_byte_pbv(&p, 0x24);
            emit_byte_pbv(&p, disp);
        } else {
            emit_byte_pbv(&p, 0x84 | (i << 3));
            emit_byte_pbv(&p, 0x24);
            int32_t d32 = disp;
            emit_pbv(&p, &d32, 4);
        }
    }

    /* Restore integer arg registers */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x3c); emit_byte_pbv(&p, 0x24);
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x74); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x08);
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x54); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x10);
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x18);
    emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x44); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x20);
    emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x8b); emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x28);

    /* Tear down frame and call original.
     * add $192, %rsp; pop %rbp */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x81); emit_byte_pbv(&p, 0xc4);
    emit_pbv(&p, &frame, 4);
    emit_byte_pbv(&p, 0x5d);  /* pop %rbp */

    /* call original via r11 */
    emit_byte_pbv(&p, 0x49); emit_byte_pbv(&p, 0xbb);
    uint64_t orig_addr = (uint64_t)original;
    emit_pbv(&p, &orig_addr, 8);
    emit_byte_pbv(&p, 0x41); emit_byte_pbv(&p, 0xff); emit_byte_pbv(&p, 0xd3);

    /* Save return: push rax, rdx, sub 32 for xmm0/xmm1 */
    emit_byte_pbv(&p, 0x50);  /* push rax */
    emit_byte_pbv(&p, 0x52);  /* push rdx */
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x83); emit_byte_pbv(&p, 0xec); emit_byte_pbv(&p, 0x20);
    /* movdqu %xmm0, (%rsp) */
    emit_byte_pbv(&p, 0xf3); emit_byte_pbv(&p, 0x0f); emit_byte_pbv(&p, 0x7f);
    emit_byte_pbv(&p, 0x04); emit_byte_pbv(&p, 0x24);
    /* movdqu %xmm1, 16(%rsp) */
    emit_byte_pbv(&p, 0xf3); emit_byte_pbv(&p, 0x0f); emit_byte_pbv(&p, 0x7f);
    emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x10);

    /* For exit dispatch, we need the original arg pointers to read output.
     * But they're gone now.  We'd need to save them before the call.
     * For now, the exit dispatch is a placeholder — output capture requires
     * saving the arg registers across the original call too.
     *
     * TODO: For full output capture, save arg regs before the call and
     * pass them to pbv_dispatch_exit.  For now, skip exit dispatch. */

    /* Restore return regs */
    emit_byte_pbv(&p, 0xf3); emit_byte_pbv(&p, 0x0f); emit_byte_pbv(&p, 0x6f);
    emit_byte_pbv(&p, 0x4c); emit_byte_pbv(&p, 0x24); emit_byte_pbv(&p, 0x10);
    emit_byte_pbv(&p, 0xf3); emit_byte_pbv(&p, 0x0f); emit_byte_pbv(&p, 0x6f);
    emit_byte_pbv(&p, 0x04); emit_byte_pbv(&p, 0x24);
    emit_byte_pbv(&p, 0x48); emit_byte_pbv(&p, 0x83); emit_byte_pbv(&p, 0xc4); emit_byte_pbv(&p, 0x20);
    emit_byte_pbv(&p, 0x5a);  /* pop rdx */
    emit_byte_pbv(&p, 0x58);  /* pop rax */

    /* ret */
    emit_byte_pbv(&p, 0xc3);

    return base;
}

#else

static void *generate_pbv_trampoline(int shim_idx, void *original)
{
    (void)shim_idx; (void)original;
    fprintf(stderr, "ldx: PbV trampoline not supported on this architecture\n");
    return NULL;
}

#endif /* __x86_64__ */

/* --- install --- */

/* Walk callback to find the target and install the trampoline. */
struct pbv_install_ctx {
    int shim_idx;
    int found;
};

static int pbv_install_walk_cb(const char *sym, const char *lib,
                               void **got_slot, void *cur_val, void *user)
{
    (void)lib;
    struct pbv_install_ctx *ctx = user;
    pbv_shim_t *shim = &pbv_shims[ctx->shim_idx];

    /* Match by function name (ignore library qualifier for now). */
    /* Extract symbol name from target. */
    const char *target_sym = shim->sig->target;
    const char *colon = strchr(target_sym, ':');
    const char *match_sym = colon ? colon + 1 : target_sym;

    if (strcmp(sym, match_sym) != 0) return 0;

    shim->original = cur_val;

    void *tramp = generate_pbv_trampoline(ctx->shim_idx, cur_val);
    if (!tramp) return 0;

    /* Patch GOT — reuse ldx's dlreplace. */
    dlreplace(shim->sig->target, tramp);

    fprintf(stderr, "ldx: PbV shim installed for %s\n", sym);
    ctx->found = 1;
    return 1;  /* stop after first match */
}

int ldx_pbv_install(ldx_sig_t *sig, ldx_pbv_callback_t cb, void *user)
{
    if (pbv_shim_count >= MAX_PBV_SHIMS) {
        fprintf(stderr, "ldx: PbV shim table full\n");
        return -1;
    }

    ldx_init();

    int idx = pbv_shim_count++;
    pbv_shim_t *shim = &pbv_shims[idx];
    shim->sig = sig;
    shim->callback = cb;
    shim->user = user;
    shim->original = NULL;

    struct pbv_install_ctx ctx = { .shim_idx = idx, .found = 0 };
    ldx_walk_got(pbv_install_walk_cb, &ctx);

    if (!ctx.found) {
        fprintf(stderr, "ldx: PbV target '%s' not found in GOT\n", sig->target);
        pbv_shim_count--;
        return -1;
    }
    return 0;
}
