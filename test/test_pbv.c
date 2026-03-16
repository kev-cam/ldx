/*
 * test_pbv.c — Test Pass-by-Value conversion: serialize, deserialize, replay.
 *
 * Proves that a function call with pointer args can be captured as a
 * flat value packet, transported (simulated), and replayed to produce
 * the same result — the prerequisite for network transport.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../src/ldx.h"
#include "../src/ldx_pbv.h"

/* ---------- Target functions to shim ---------- */

typedef struct {
    double x, y, z;
} vec3_t;

/* Compute distance between two points.  Pure input pointers. */
static double vec3_distance(const vec3_t *a, const vec3_t *b)
{
    double dx = a->x - b->x;
    double dy = a->y - b->y;
    double dz = a->z - b->z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

/* Scale a vector in-place.  INOUT pointer. */
static void vec3_scale(vec3_t *v, double factor)
{
    v->x *= factor;
    v->y *= factor;
    v->z *= factor;
}

/* ---------- Test 1: manual serialize/deserialize roundtrip ---------- */

static int test_serialize_roundtrip(void)
{
    printf("test_serialize_roundtrip: ");

    /* Describe vec3_distance(const vec3_t *a, const vec3_t *b) */
    ldx_sig_t *sig = ldx_sig_create("vec3_distance", "vec3_distance");
    ldx_sig_add_arg(sig, "a", LDX_ARG_PTR_IN, LDX_TYPE_STRUCT, sizeof(vec3_t));
    ldx_sig_add_arg(sig, "b", LDX_ARG_PTR_IN, LDX_TYPE_STRUCT, sizeof(vec3_t));
    ldx_sig_set_return(sig, LDX_TYPE_DOUBLE, sizeof(double));

    /* Set up test data. */
    vec3_t a = {1.0, 2.0, 3.0};
    vec3_t b = {4.0, 6.0, 8.0};

    /* Simulate register args: rdi = &a, rsi = &b */
    uint64_t regs[8] = {0};
    regs[0] = (uint64_t)(uintptr_t)&a;
    regs[1] = (uint64_t)(uintptr_t)&b;

    /* Serialize — this dereferences the pointers into a flat packet. */
    ldx_packet_t *pkt = ldx_pbv_serialize(sig, regs, 0);
    if (!pkt) {
        printf("FAIL (serialize returned NULL)\n");
        ldx_sig_free(sig);
        return 1;
    }

    /* Dump the packet for inspection. */
    ldx_packet_dump(sig, pkt);

    /* Deserialize — reconstruct args from the packet.
     * This allocates NEW buffers for the pointer args. */
    ldx_deser_ctx_t dctx;
    if (ldx_pbv_deserialize(sig, pkt, &dctx) != 0) {
        printf("FAIL (deserialize failed)\n");
        free(pkt);
        ldx_sig_free(sig);
        return 1;
    }

    /* The deserialized pointers point to COPIES of the original data.
     * Verify the copies match. */
    vec3_t *a2 = (vec3_t *)(uintptr_t)dctx.reg_args[0];
    vec3_t *b2 = (vec3_t *)(uintptr_t)dctx.reg_args[1];

    if (memcmp(&a, a2, sizeof(vec3_t)) != 0 ||
        memcmp(&b, b2, sizeof(vec3_t)) != 0) {
        printf("FAIL (deserialized data doesn't match)\n");
        ldx_pbv_deser_free(&dctx);
        free(pkt);
        ldx_sig_free(sig);
        return 1;
    }

    /* Replay the call using deserialized data. */
    double result_original = vec3_distance(&a, &b);
    double result_replay = vec3_distance(a2, b2);

    ldx_pbv_deser_free(&dctx);
    free(pkt);
    ldx_sig_free(sig);

    if (fabs(result_original - result_replay) > 1e-15) {
        printf("FAIL (original=%f replay=%f)\n", result_original, result_replay);
        return 1;
    }

    printf("PASS (distance=%f, roundtrip exact match)\n", result_original);
    return 0;
}

/* ---------- Test 2: serialize with mixed val/ptr args ---------- */

static int test_mixed_args(void)
{
    printf("test_mixed_args: ");

    /* Describe vec3_scale(vec3_t *v, double factor)
     * arg0: ptr_inout (struct), arg1: val (double) */
    ldx_sig_t *sig = ldx_sig_create("vec3_scale", "vec3_scale");
    ldx_sig_add_arg(sig, "v", LDX_ARG_PTR_INOUT, LDX_TYPE_STRUCT, sizeof(vec3_t));
    ldx_sig_add_arg(sig, "factor", LDX_ARG_VAL, LDX_TYPE_DOUBLE, sizeof(double));

    vec3_t v = {2.0, 4.0, 6.0};
    double factor = 0.5;

    uint64_t regs[8] = {0};
    regs[0] = (uint64_t)(uintptr_t)&v;
    memcpy(&regs[1], &factor, sizeof(double));  /* double passed in integer reg for this test */

    ldx_packet_t *pkt = ldx_pbv_serialize(sig, regs, 0);
    if (!pkt) {
        printf("FAIL (serialize returned NULL)\n");
        ldx_sig_free(sig);
        return 1;
    }

    ldx_packet_dump(sig, pkt);

    /* Deserialize and replay. */
    ldx_deser_ctx_t dctx;
    ldx_pbv_deserialize(sig, pkt, &dctx);

    vec3_t *v2 = (vec3_t *)(uintptr_t)dctx.reg_args[0];
    double f2;
    memcpy(&f2, &dctx.reg_args[1], sizeof(double));

    /* Replay vec3_scale on the deserialized copy. */
    vec3_t v_copy = *v2;  /* save pre-scale state */
    vec3_scale(v2, f2);

    /* Also run on original for comparison. */
    vec3_t v_orig = v;
    vec3_scale(&v_orig, factor);

    int ok = (fabs(v2->x - v_orig.x) < 1e-15 &&
              fabs(v2->y - v_orig.y) < 1e-15 &&
              fabs(v2->z - v_orig.z) < 1e-15);

    ldx_pbv_deser_free(&dctx);
    free(pkt);
    ldx_sig_free(sig);

    if (!ok) {
        printf("FAIL (replay mismatch)\n");
        return 1;
    }

    printf("PASS (scaled to [%g, %g, %g])\n", v_orig.x, v_orig.y, v_orig.z);
    return 0;
}

/* ---------- Test 3: live PbV shim via GOT patching ---------- */

/* We need a function that goes through the GOT (dynamically linked).
 * Use strlen as our target — describe it as taking a PTR_IN string. */

static int packet_count = 0;
static ldx_packet_t *last_packet = NULL;

static void capture_callback(const ldx_sig_t *sig, const ldx_packet_t *pkt,
                             void *user)
{
    (void)user;
    packet_count++;
    fprintf(stderr, "  [capture #%d]\n", packet_count);
    ldx_packet_dump(sig, pkt);

    /* Save a copy of the packet. */
    if (last_packet) free(last_packet);
    size_t total = sizeof(ldx_packet_t) + pkt->total_size;
    last_packet = malloc(total);
    memcpy(last_packet, pkt, total);
}

static int test_live_shim(void)
{
    printf("test_live_shim: ");

    /* Describe strlen(const char *s) */
    ldx_sig_t *sig = ldx_sig_create("strlen", "strlen");
    ldx_sig_add_arg(sig, "s", LDX_ARG_PTR_IN, LDX_TYPE_STRING, 0);
    ldx_sig_set_return(sig, LDX_TYPE_LONG, sizeof(size_t));

    packet_count = 0;
    last_packet = NULL;

    int rc = ldx_pbv_install(sig, capture_callback, NULL);
    if (rc != 0) {
        printf("FAIL (ldx_pbv_install returned %d)\n", rc);
        ldx_sig_free(sig);
        return 1;
    }

    /* Call strlen normally — the shim should capture it. */
    volatile size_t len = strlen("hello PbV!");
    if (len != 10) {
        printf("FAIL (strlen returned %zu, expected 10)\n", len);
        ldx_sig_free(sig);
        return 1;
    }

    if (packet_count < 1) {
        printf("FAIL (no packets captured)\n");
        ldx_sig_free(sig);
        return 1;
    }

    /* Verify the captured packet contains "hello PbV!" */
    if (!last_packet) {
        printf("FAIL (last_packet is NULL)\n");
        ldx_sig_free(sig);
        return 1;
    }

    /* Deserialize and replay. */
    ldx_deser_ctx_t dctx;
    ldx_pbv_deserialize(sig, last_packet, &dctx);
    const char *captured_str = (const char *)(uintptr_t)dctx.reg_args[0];

    if (!captured_str || strcmp(captured_str, "hello PbV!") != 0) {
        printf("FAIL (captured string: '%s')\n", captured_str ? captured_str : "(null)");
        ldx_pbv_deser_free(&dctx);
        ldx_sig_free(sig);
        return 1;
    }

    ldx_pbv_deser_free(&dctx);
    free(last_packet);
    last_packet = NULL;

    printf("PASS (captured \"%s\", %d packet(s))\n", "hello PbV!", packet_count);
    /* Don't free sig — it's held by the shim table */
    return 0;
}

/* ---------- main ---------- */

int main(void)
{
    int failures = 0;

    printf("=== ldx PbV tests ===\n");
    failures += test_serialize_roundtrip();
    failures += test_mixed_args();
    failures += test_live_shim();

    printf("=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
