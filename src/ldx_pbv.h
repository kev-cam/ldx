#ifndef LDX_PBV_H
#define LDX_PBV_H

#include <stddef.h>
#include <stdint.h>

/*
 * ldx PbV (Pass-by-Value) conversion layer.
 *
 * Describes function signatures, serializes pointer arguments into
 * flat buffers, and generates shims that capture calls as self-contained
 * packets ready for network transport.
 */

/* Argument direction: how pointer data flows. */
#define LDX_ARG_VAL     0   /* passed by value (int, double, etc.) — no deref needed */
#define LDX_ARG_PTR_IN  1   /* pointer to input data — deref and serialize on entry */
#define LDX_ARG_PTR_OUT 2   /* pointer to output data — serialize on exit */
#define LDX_ARG_PTR_INOUT 3 /* pointer to input+output data — both */

/* Argument type tags for serialization. */
#define LDX_TYPE_INT      1
#define LDX_TYPE_UINT     2
#define LDX_TYPE_LONG     3
#define LDX_TYPE_ULONG    4
#define LDX_TYPE_FLOAT    5
#define LDX_TYPE_DOUBLE   6
#define LDX_TYPE_PTR      7   /* opaque pointer (size_t) — not dereferenceable */
#define LDX_TYPE_STRUCT   8   /* blob of known size */
#define LDX_TYPE_STRING   9   /* null-terminated string (variable length) */
#define LDX_TYPE_VOID     0

#define LDX_MAX_ARGS 8

/* Describes one function argument. */
typedef struct {
    const char *name;       /* argument name (for debugging/config) */
    int         direction;  /* LDX_ARG_VAL, PTR_IN, PTR_OUT, PTR_INOUT */
    int         type;       /* LDX_TYPE_* */
    size_t      size;       /* size in bytes (for STRUCT/fixed-size types) */
} ldx_arg_desc_t;

/* Describes a function's full signature. */
typedef struct {
    char            name[128];
    char            target[256];  /* dlreplace target (e.g. "libm.so:compute") */
    ldx_arg_desc_t  args[LDX_MAX_ARGS];
    int             nargs;
    int             ret_type;     /* LDX_TYPE_* for return value */
    size_t          ret_size;
} ldx_sig_t;

/* Serialized call packet.  Flat buffer containing all argument data
 * by value — no pointers.  Ready for network transport. */
typedef struct {
    char          func_name[128];
    uint32_t      nargs;
    uint32_t      total_size;     /* total payload bytes */
    /* Followed by: arg headers + data (see ldx_pbv_serialize) */
    unsigned char payload[];      /* flexible array member */
} ldx_packet_t;

/* Per-argument header inside the payload. */
typedef struct {
    uint32_t arg_index;
    uint32_t direction;
    uint32_t type;
    uint32_t data_size;       /* actual serialized size */
    /* Followed by data_size bytes of argument data */
} ldx_arg_header_t;

/* --- Signature API --- */

/* Create a signature description.  target uses dlreplace format. */
ldx_sig_t *ldx_sig_create(const char *name, const char *target);

/* Add an argument to the signature. */
int ldx_sig_add_arg(ldx_sig_t *sig, const char *name,
                    int direction, int type, size_t size);

/* Set return type. */
void ldx_sig_set_return(ldx_sig_t *sig, int type, size_t size);

/* Free a signature. */
void ldx_sig_free(ldx_sig_t *sig);

/* --- Serialization --- */

/* Serialize a function call's arguments into a packet.
 * reg_args[]: the raw register values (up to 6 integer args on x86_64).
 * For VAL args, the value is used directly.
 * For PTR_* args, the pointer is dereferenced and the data copied.
 * Returns malloc'd packet (caller frees), or NULL on error. */
ldx_packet_t *ldx_pbv_serialize(const ldx_sig_t *sig, uint64_t reg_args[],
                                int capture_output);

/* Deserialize: reconstruct argument values from a packet.
 * For PTR_* args, allocates temporary buffers and stores pointers.
 * reg_args[] is filled with values suitable for calling the function.
 * Returns 0 on success.  Caller must call ldx_pbv_deser_free() after. */
typedef struct {
    uint64_t reg_args[LDX_MAX_ARGS];
    void    *alloc_ptrs[LDX_MAX_ARGS];  /* allocated buffers to free */
    int      nalloc;
} ldx_deser_ctx_t;

int ldx_pbv_deserialize(const ldx_sig_t *sig, const ldx_packet_t *pkt,
                        ldx_deser_ctx_t *ctx);
void ldx_pbv_deser_free(ldx_deser_ctx_t *ctx);

/* --- PbV Shim --- */

/* Callback invoked when a PbV-shimmed function is called.
 * Receives the serialized packet of input args.
 * This is the hook point for logging, recording, or network forwarding. */
typedef void (*ldx_pbv_callback_t)(const ldx_sig_t *sig,
                                   const ldx_packet_t *pkt,
                                   void *user);

/* Install a PbV shim for the described function.
 * The shim intercepts calls, serializes args, invokes the callback,
 * then calls the original function normally.
 * After the original returns, it serializes output args and invokes
 * the callback again (with capture_output=1).
 * Returns 0 on success. */
int ldx_pbv_install(ldx_sig_t *sig, ldx_pbv_callback_t cb, void *user);

/* Dump a packet to stderr in human-readable form. */
void ldx_packet_dump(const ldx_sig_t *sig, const ldx_packet_t *pkt);

#endif /* LDX_PBV_H */
