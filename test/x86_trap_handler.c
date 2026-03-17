/*
 * x86_trap_handler.c — LD_PRELOAD library that catches UD2 traps and
 * dispatches to software (or FPGA) accelerator implementations.
 *
 * This is the userspace equivalent of a kernel #UD handler. Uses
 * SIGILL signal to catch the undefined instruction, reads the 3-byte
 * payload after UD2, dispatches, and advances RIP past the 5-byte
 * replacement sequence.
 *
 * For FPGA: replace the software implementations with MMIO writes.
 *
 * Usage:
 *   LD_PRELOAD=./x86_trap_handler.so ./patched_binary
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <signal.h>
#include <ucontext.h>
#include <math.h>
#include <string.h>

/* Dispatch table for custom operations.
 * class:opcode → function */

typedef void (*accel_fn)(ucontext_t *ctx);

/* Math operations (class 0x00):
 *   0x00 = sin(xmm0) → xmm0
 *   0x01 = cos(xmm0) → xmm0
 *   0x02 = sqrt(xmm0) → xmm0
 *   0x03 = exp(xmm0) → xmm0
 *   0x04 = log(xmm0) → xmm0
 */

static double get_xmm0(ucontext_t *ctx)
{
    /* XMM registers are in fpregs (FXSAVE area). */
    double val;
    memcpy(&val, &ctx->uc_mcontext.fpregs->_xmm[0], sizeof(double));
    return val;
}

static void set_xmm0(ucontext_t *ctx, double val)
{
    memcpy(&ctx->uc_mcontext.fpregs->_xmm[0], &val, sizeof(double));
}

static void accel_sin(ucontext_t *ctx)  { set_xmm0(ctx, sin(get_xmm0(ctx))); }
static void accel_cos(ucontext_t *ctx)  { set_xmm0(ctx, cos(get_xmm0(ctx))); }
static void accel_sqrt(ucontext_t *ctx) { set_xmm0(ctx, sqrt(get_xmm0(ctx))); }
static void accel_exp(ucontext_t *ctx)  { set_xmm0(ctx, exp(get_xmm0(ctx))); }
static void accel_log(ucontext_t *ctx)  { set_xmm0(ctx, log(get_xmm0(ctx))); }

/* Dispatch table: [class][opcode] */
#define MAX_CLASS 4
#define MAX_OP    16

static accel_fn dispatch[MAX_CLASS][MAX_OP] = {
    /* class 0: math */
    [0] = {
        [0] = accel_sin,
        [1] = accel_cos,
        [2] = accel_sqrt,
        [3] = accel_exp,
        [4] = accel_log,
    },
    /* class 1: logic (4-state) — placeholder */
    /* class 2: crypto — placeholder */
};

static unsigned long trap_count = 0;

static void sigill_handler(int sig, siginfo_t *info, void *ucontext)
{
    (void)sig; (void)info;
    ucontext_t *ctx = (ucontext_t *)ucontext;
    unsigned char *rip = (unsigned char *)ctx->uc_mcontext.gregs[REG_RIP];

    /* Check for our UD2 + payload pattern. */
    if (rip[0] == 0x0F && rip[1] == 0x0B) {
        unsigned char op_class = rip[2];
        unsigned char op_code = rip[3];
        /* unsigned char reg_hint = rip[4]; */

        if (op_class < MAX_CLASS && op_code < MAX_OP && dispatch[op_class][op_code]) {
            dispatch[op_class][op_code](ctx);
            trap_count++;

            /* Advance RIP past the 5-byte replacement. */
            ctx->uc_mcontext.gregs[REG_RIP] += 5;
            return;
        }

        fprintf(stderr, "x86-trap: unknown custom op class=%d code=%d at %p\n",
                op_class, op_code, (void *)rip);
    }

    /* Not our UD2 — re-raise. */
    signal(SIGILL, SIG_DFL);
    raise(SIGILL);
}

__attribute__((constructor))
static void install_trap_handler(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigill_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGILL, &sa, NULL);
    fprintf(stderr, "x86-trap: handler installed\n");
}

__attribute__((destructor))
static void report_traps(void)
{
    if (trap_count > 0)
        fprintf(stderr, "x86-trap: handled %lu custom instruction traps\n", trap_count);
}
