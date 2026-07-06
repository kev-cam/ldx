#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>

/* Contention-free flat allreduce: each thread publishes value+generation
   in its own cache line; leader polls N independent lines, sums, and
   publishes one result line all others snoop. No shared counter, one
   phase per op. Workers may not start generation g+1 until they've seen
   the g result, which guarantees the leader has consumed their g slot. */

#define MAXN 16
typedef struct { _Atomic uint64_t seq; double v; char pad[48]; } slot_t;
static slot_t slots[MAXN] __attribute__((aligned(64)));
static slot_t result __attribute__((aligned(64)));

static int nthreads;
static long iters = 200000;
static double elapsed_ns;

static void pin(int cpu) {
  cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s);
  pthread_setaffinity_np(pthread_self(), sizeof(s), &s);
}

static void *worker(void *arg) {
  int me = (int)(long)arg;
  pin(me);
  struct timespec a, b;
  if (me == 0) clock_gettime(CLOCK_MONOTONIC, &a);
  for (long i = 0; i < iters; i++) {
    uint64_t gen = i + 1;
    slots[me].v = me + (double)i;
    atomic_store_explicit(&slots[me].seq, gen, memory_order_release);
    if (me == 0) {
      double s = 0;
      for (int n = 0; n < nthreads; n++) {
        while (atomic_load_explicit(&slots[n].seq, memory_order_acquire) != gen)
          __builtin_ia32_pause();
        s += slots[n].v;
      }
      result.v = s;
      atomic_store_explicit(&result.seq, gen, memory_order_release);
    } else {
      while (atomic_load_explicit(&result.seq, memory_order_acquire) != gen)
        __builtin_ia32_pause();
    }
    volatile double r = result.v; (void)r;
  }
  if (me == 0) {
    clock_gettime(CLOCK_MONOTONIC, &b);
    elapsed_ns = (b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec);
  }
  return 0;
}

int main(int argc, char **argv) {
  nthreads = (argc > 1) ? atoi(argv[1]) : 8;
  if (argc > 2) iters = atol(argv[2]);
  pthread_t t[MAXN];
  for (int i = 1; i < nthreads; i++)
    pthread_create(&t[i], 0, worker, (void *)(long)i);
  worker(0);
  for (int i = 1; i < nthreads; i++) pthread_join(t[i], 0);
  printf("n=%d shm allreduce v2 (1 double): %.0f ns/op\n", nthreads, elapsed_ns / iters);
  return 0;
}
