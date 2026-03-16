/*
 * test_basic.c — Prove that dlreplace can redirect a libc function at runtime.
 *
 * Build:  make
 * Run:    ./test/test_basic          (links ldx directly)
 *    or:  LD_PRELOAD=./libldx.so ./test/test_basic_noldx
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../src/ldx.h"

/* ---------- Test 1: replace strlen ---------- */

static size_t fake_strlen(const char *s)
{
    (void)s;
    return 42;  /* always returns 42 */
}

static int test_replace_strlen(void)
{
    printf("test_replace_strlen: ");

    /* Before replacement, strlen should work normally. */
    size_t real = strlen("hello");
    if (real != 5) {
        printf("FAIL (pre-replace strlen returned %zu, expected 5)\n", real);
        return 1;
    }

    /* Replace strlen globally. */
    void *orig = dlreplace("strlen", (void *)fake_strlen);
    if (!orig) {
        printf("FAIL (dlreplace returned NULL — no GOT entry found)\n");
        return 1;
    }

    /* After replacement, strlen should return 42. */
    size_t faked = strlen("hello");
    if (faked != 42) {
        printf("FAIL (post-replace strlen returned %zu, expected 42)\n", faked);
        return 1;
    }

    /* Restore original. */
    dlreplace("strlen", orig);
    size_t restored = strlen("hello");
    if (restored != 5) {
        printf("FAIL (restored strlen returned %zu, expected 5)\n", restored);
        return 1;
    }

    printf("PASS\n");
    return 0;
}

/* ---------- Test 2: library-qualified replace ---------- */

static double fake_sin(double x)
{
    (void)x;
    return 99.0;
}

static int test_replace_libqualified(void)
{
    printf("test_replace_libqualified: ");

    double real = sin(1.0);
    if (real < 0.84 || real > 0.85) {
        printf("FAIL (pre-replace sin(1.0) = %f)\n", real);
        return 1;
    }

    /* Replace sin only from libm. */
    void *orig = dlreplace("libm.so:sin", (void *)fake_sin);
    /* Note: the lib name in the GOT walk is the full path, so we use
     * substring matching.  "libm.so" should match "/lib/.../libm.so.6". */

    double faked = sin(1.0);
    if (faked != 99.0) {
        /* This can fail if sin is resolved from a different library name
         * or if the compiler inlined sin.  Use -fno-builtin-sin. */
        printf("FAIL (post-replace sin(1.0) = %f, expected 99.0)\n", faked);
        if (orig) dlreplace("libm.so:sin", orig);
        return 1;
    }

    dlreplace("sin", orig);
    printf("PASS\n");
    return 0;
}

/* ---------- Test 3: dlreplaceq with glob pattern ---------- */

static int replaceq_called = 0;

static void *my_replaceq_cb(const char *sym, const char *lib, void *cur)
{
    (void)lib; (void)cur;
    if (strcmp(sym, "strlen") == 0) {
        replaceq_called = 1;
        return (void *)fake_strlen;
    }
    return NULL;
}

static int test_replaceq(void)
{
    printf("test_replaceq: ");

    replaceq_called = 0;
    int count = dlreplaceq("str*", my_replaceq_cb);

    if (!replaceq_called) {
        printf("FAIL (callback never called for strlen)\n");
        return 1;
    }

    size_t faked = strlen("hello");
    if (faked != 42) {
        printf("FAIL (strlen returned %zu after replaceq, expected 42)\n", faked);
        return 1;
    }

    /* Restore. */
    dlreplace("strlen", (void *)strlen);  /* point back to real strlen from direct link */

    printf("PASS (matched %d slots)\n", count);
    return 0;
}

/* ---------- Test 4: ldx_walk_got enumerates symbols ---------- */

static int walk_found_strlen = 0;
static int walk_found_sin = 0;
static int walk_total = 0;

static int walk_cb(const char *sym, const char *lib,
                   void **got_slot, void *cur_val, void *user)
{
    (void)lib; (void)got_slot; (void)cur_val; (void)user;
    walk_total++;
    if (strcmp(sym, "strlen") == 0) walk_found_strlen = 1;
    if (strcmp(sym, "sin") == 0) walk_found_sin = 1;
    return 0;
}

static int test_walk_got(void)
{
    printf("test_walk_got: ");

    ldx_walk_got(walk_cb, NULL);

    if (walk_total == 0) {
        printf("FAIL (no GOT entries found at all)\n");
        return 1;
    }
    if (!walk_found_strlen) {
        printf("FAIL (strlen not found in GOT walk, %d entries total)\n", walk_total);
        return 1;
    }
    if (!walk_found_sin) {
        printf("FAIL (sin not found in GOT walk, %d entries total)\n", walk_total);
        return 1;
    }

    printf("PASS (%d GOT entries, strlen+sin found)\n", walk_total);
    return 0;
}

/* ---------- main ---------- */

int main(void)
{
    int failures = 0;

    printf("=== ldx basic tests ===\n");

    failures += test_walk_got();
    failures += test_replace_strlen();
    failures += test_replace_libqualified();
    failures += test_replaceq();

    printf("=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
