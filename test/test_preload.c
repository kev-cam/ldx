/*
 * test_preload.c — Test that ldx works via LD_PRELOAD on an unmodified binary.
 *
 * This program just calls strlen and prints the result.
 * When LD_PRELOADed with libldx.so + a config library, strlen gets replaced.
 *
 * Usage:
 *   gcc -fno-builtin-strlen -o test_preload test_preload.c
 *   LD_PRELOAD=../libldx.so:./preload_hook.so ./test_preload
 */
#include <stdio.h>
#include <string.h>

int main(void)
{
    const char *s = "hello world";
    size_t len = strlen(s);
    printf("strlen(\"%s\") = %zu\n", s, len);

    if (len == 42) {
        printf("PRELOAD TEST: PASS (strlen was replaced)\n");
        return 0;
    } else if (len == 11) {
        printf("PRELOAD TEST: normal strlen (no replacement active)\n");
        return 0;
    } else {
        printf("PRELOAD TEST: FAIL (unexpected result %zu)\n", len);
        return 1;
    }
}
