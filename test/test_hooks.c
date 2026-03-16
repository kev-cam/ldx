/*
 * test_hooks.c — Test runtime trampoline generation and profiling.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "../src/ldx.h"

/* ---------- Test 1: hook fires on entry and exit ---------- */

static volatile int hook_entry_count = 0;
static volatile int hook_exit_count = 0;

static void test_hook(const char *sym, const char *lib,
                      int is_exit, unsigned long thread_id,
                      double timestamp)
{
    (void)sym; (void)lib; (void)thread_id; (void)timestamp;
    if (is_exit)
        hook_exit_count++;
    else
        hook_entry_count++;
}

static int test_hook_fires(void)
{
    printf("test_hook_fires: ");

    hook_entry_count = 0;
    hook_exit_count = 0;

    int rc = ldx_add_hook("strlen", test_hook);
    if (rc != 0) {
        printf("FAIL (ldx_add_hook returned %d)\n", rc);
        return 1;
    }

    /* Call strlen — should trigger hook entry + exit. */
    size_t len = strlen("hello");
    if (len != 5) {
        printf("FAIL (strlen returned %zu, expected 5)\n", len);
        return 1;
    }

    if (hook_entry_count != 1) {
        printf("FAIL (entry hook fired %d times, expected 1)\n", hook_entry_count);
        return 1;
    }
    if (hook_exit_count != 1) {
        printf("FAIL (exit hook fired %d times, expected 1)\n", hook_exit_count);
        return 1;
    }

    /* Call again — use volatile to prevent optimization. */
    volatile size_t len2 = strlen("world!");
    (void)len2;
    if (hook_entry_count != 2 || hook_exit_count != 2) {
        printf("FAIL (after 2 calls: entry=%d exit=%d)\n",
               hook_entry_count, hook_exit_count);
        return 1;
    }

    printf("PASS\n");
    return 0;
}

/* ---------- Test 2: hook preserves return value ---------- */

static void noop_hook(const char *sym, const char *lib,
                      int is_exit, unsigned long thread_id,
                      double timestamp)
{
    (void)sym; (void)lib; (void)is_exit; (void)thread_id; (void)timestamp;
}

static int test_hook_preserves_retval(void)
{
    printf("test_hook_preserves_retval: ");

    ldx_add_hook("sin", noop_hook);

    /* sin(0) = 0.0, sin(pi/2) ≈ 1.0, sin(pi/6) ≈ 0.5 */
    double v1 = sin(0.0);
    double v2 = sin(M_PI / 2.0);
    double v3 = sin(M_PI / 6.0);

    if (v1 != 0.0) {
        printf("FAIL (sin(0) = %f, expected 0.0)\n", v1);
        return 1;
    }
    if (fabs(v2 - 1.0) > 1e-10) {
        printf("FAIL (sin(pi/2) = %.15f, expected 1.0)\n", v2);
        return 1;
    }
    if (fabs(v3 - 0.5) > 1e-10) {
        printf("FAIL (sin(pi/6) = %.15f, expected 0.5)\n", v3);
        return 1;
    }

    printf("PASS\n");
    return 0;
}

/* ---------- Test 3: profiler collects timing ---------- */

static int test_profiler(void)
{
    printf("test_profiler: ");

    int rc = ldx_prof_add("cos");
    if (rc != 0) {
        printf("FAIL (ldx_prof_add returned %d)\n", rc);
        return 1;
    }

    /* Call cos 1000 times. */
    volatile double sum = 0;
    for (int i = 0; i < 1000; i++) {
        sum += cos((double)i * 0.001);
    }
    (void)sum;

    ldx_prof_entry_t entry;
    int n = ldx_prof_get(&entry, 1);
    if (n < 1) {
        printf("FAIL (no profiling data)\n");
        return 1;
    }

    if (entry.call_count != 1000) {
        printf("FAIL (call_count=%lu, expected 1000)\n", entry.call_count);
        return 1;
    }
    if (entry.total_time <= 0) {
        printf("FAIL (total_time=%f, expected > 0)\n", entry.total_time);
        return 1;
    }
    if (entry.min_time > entry.max_time) {
        printf("FAIL (min=%f > max=%f)\n", entry.min_time, entry.max_time);
        return 1;
    }

    printf("PASS (1000 calls, total=%.3fms, avg=%.3fus)\n",
           entry.total_time * 1e3,
           (entry.total_time / entry.call_count) * 1e6);

    ldx_prof_report();
    return 0;
}

/* ---------- main ---------- */

int main(void)
{
    int failures = 0;

    printf("=== ldx hook/profiler tests ===\n");
    failures += test_hook_fires();
    failures += test_hook_preserves_retval();
    failures += test_profiler();

    printf("=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
