#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>

/* Single-cache-line ping-pong between two pinned threads.
   Each turn is one coherence-protocol line transfer; reported
   latency is per one-way handoff. */

typedef struct { _Atomic uint64_t flag; char pad[56]; } line_t;
static line_t line __attribute__((aligned(64)));
static long rounds = 5000000;

static void pin(int cpu) {
  cpu_set_t s; CPU_ZERO(&s); CPU_SET(cpu, &s);
  pthread_setaffinity_np(pthread_self(), sizeof(s), &s);
}

static void *pong(void *arg) {
  pin((int)(long)arg);
  for (long i = 0; i < rounds; i++) {
    while (atomic_load_explicit(&line.flag, memory_order_acquire) != (uint64_t)(2*i + 1))
      __builtin_ia32_pause();
    atomic_store_explicit(&line.flag, 2*i + 2, memory_order_release);
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s cpuA cpuB [rounds]\n", argv[0]); return 1; }
  int c0 = atoi(argv[1]), c1 = atoi(argv[2]);
  if (argc > 3) rounds = atol(argv[3]);

  pthread_t t;
  pthread_create(&t, 0, pong, (void *)(long)c1);
  pin(c0);

  struct timespec a, b;
  clock_gettime(CLOCK_MONOTONIC, &a);
  for (long i = 0; i < rounds; i++) {
    atomic_store_explicit(&line.flag, 2*i + 1, memory_order_release);
    while (atomic_load_explicit(&line.flag, memory_order_acquire) != (uint64_t)(2*i + 2))
      __builtin_ia32_pause();
  }
  clock_gettime(CLOCK_MONOTONIC, &b);
  pthread_join(t, 0);

  double ns = (b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec);
  printf("cpu%d<->cpu%d: %.1f ns one-way (%ld round trips)\n",
         c0, c1, ns / (2.0 * rounds), rounds);
  return 0;
}
