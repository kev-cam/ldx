#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>

/* Flat shared-memory allreduce over N pinned threads:
   padded per-thread slots + central counter barrier, leader sums.
   Two barriers per op — conservative model of the scheme
   proposed for the Xyce shm Communicator. */

#define MAXN 16
typedef struct { double v; char pad[56]; } slot_t;
static slot_t slots[MAXN] __attribute__((aligned(64)));
static struct { double v; char pad[56]; } result __attribute__((aligned(64)));

static _Atomic int bcount;
static _Atomic uint64_t bphase;
static int nthreads;
static long iters = 200000;

static void barrier_wait(void) {
  uint64_t p = atomic_load_explicit(&bphase, memory_order_acquire);
  if (atomic_fetch_add_explicit(&bcount, 1, memory_order_acq_rel) == nthreads - 1) {
    atomic_store_explicit(&bcount, 0, memory_order_relaxed);
    atomic_fetch_add_explicit(&bphase, 1, memory_order_release);
  } else {
    while (atomic_load_explicit(&bphase, memory_order_acquire) == p)
      __builtin_ia32_pause();
  }
}

static void pin(int cpu) {
  cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s);
  pthread_setaffinity_np(pthread_self(), sizeof(s), &s);
}

static double elapsed_ns;

static void *worker(void *arg) {
  int me = (int)(long)arg;
  pin(me);
  struct timespec a, b;
  if (me == 0) clock_gettime(CLOCK_MONOTONIC, &a);
  for (long i = 0; i < iters; i++) {
    slots[me].v = me + (double)i;
    barrier_wait();
    if (me == 0) {
      double s = 0;
      for (int n = 0; n < nthreads; n++) s += slots[n].v;
      result.v = s;
    }
    barrier_wait();
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
  printf("n=%d shm allreduce(1 double): %.0f ns/op\n", nthreads, elapsed_ns / iters);
  return 0;
}
