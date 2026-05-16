// patch_demo.c — first proof of LDX live-patch.
//
// We route calls to compute() through a `volatile` function pointer so
// GCC can't see the call as pure and CSE the second result. We also feed
// the argument from argc so it's not a compile-time constant.
//
// Expected: before patch, compute(argc)=argc+1; after, compute(argc)=argc*2.

#include <stdio.h>
#include "ldx_rt.h"

__attribute__((noinline, used))
int compute(int x) { return x + 1; }

__attribute__((noinline, used))
int replacement(int x) { return x * 2; }

typedef int (*fn_t)(int);
static fn_t volatile compute_fp = compute;

int main(int argc, char **argv) {
    (void)argv;
    int a = (*compute_fp)(argc);
    printf("before: compute(%d) = %d  (expect %d)\n", argc, a, argc + 1);

    int rc = ldx_patch_function((void *)compute, (void *)replacement);
    if (rc != 0) { fprintf(stderr, "patch failed: %d\n", rc); return 1; }

    int b = (*compute_fp)(argc);
    printf("after:  compute(%d) = %d  (expect %d)\n", argc, b, argc * 2);

    return (a == argc + 1 && b == argc * 2) ? 0 : 1;
}
