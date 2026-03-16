/*
 * preload_hook.c — Example LD_PRELOAD companion that uses ldx to replace strlen.
 *
 * This shows the pattern: a constructor in a preloaded .so calls dlreplace()
 * to rewire symbols before main() runs.
 */
#define _GNU_SOURCE
#include <stddef.h>
#include "../src/ldx.h"

static size_t fake_strlen(const char *s)
{
    (void)s;
    return 42;
}

__attribute__((constructor))
static void hook_init(void)
{
    dlreplace("strlen", (void *)fake_strlen);
}
