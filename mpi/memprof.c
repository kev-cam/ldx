/* memprof.c — LD_PRELOAD allocation census for the wandering-threads work.
 *
 * Answers "which are the largest C++ objects in a simulation": every
 * malloc/calloc/realloc at or above MEMPROF_MIN bytes (default 64KB) is
 * attributed to a 4-frame call chain (operator new routes through malloc in
 * glibc, so C++ allocations are covered); per-site live/peak/total bytes are
 * tracked through free/realloc. Small allocations aggregate into log2
 * buckets. Report to stderr at exit, sites ranked by peak live bytes.
 *
 * Build: gcc -O2 -shared -fPIC -o libmemprof.so memprof.c -ldl
 * Use:   LD_PRELOAD=./libmemprof.so [MEMPROF_MIN=65536] cmd...
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void *(*real_malloc)(size_t);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static void (*real_free)(void *);

/* bootstrap arena: dlsym itself allocates */
static char boot[65536];
static size_t bootn;
static __thread int inhook;

static size_t min_big = 65536;

#define NSITE 4096
static struct site {
  void *k[4];
  long long alive, peak, total;
  long calls;
} sites[NSITE];

#define NLIVE (1 << 20)
static struct liveent { void *p; int site; size_t sz; } live[NLIVE];

static long long g_alive, g_peak;
static long long small_bytes[48], small_count[48];
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

static void init_real(void) {
  real_malloc = (void *(*)(size_t))dlsym(RTLD_NEXT, "malloc");
  real_calloc = (void *(*)(size_t, size_t))dlsym(RTLD_NEXT, "calloc");
  real_realloc = (void *(*)(void *, size_t))dlsym(RTLD_NEXT, "realloc");
  real_free = (void (*)(void *))dlsym(RTLD_NEXT, "free");
  const char *e = getenv("MEMPROF_MIN");
  if (e) min_big = strtoull(e, 0, 10);
}

static unsigned live_slot(void *p) {
  return (unsigned)(((uintptr_t)p >> 4) * 2654435761u) & (NLIVE - 1);
}

static void track(void *p, size_t sz) {
  void *bt[7];
  int n = backtrace(bt, 7);
  void *k[4] = {n > 2 ? bt[2] : 0, n > 3 ? bt[3] : 0, n > 4 ? bt[4] : 0,
                n > 5 ? bt[5] : 0};
  unsigned h = 0;
  for (int i = 0; i < 4; i++) h = h * 31 + (unsigned)((uintptr_t)k[i] >> 4);
  pthread_mutex_lock(&mu);
  int si = -1;
  for (int i = 0; i < NSITE; i++) {
    unsigned j = (h + i) % NSITE;
    if (!sites[j].calls) {
      memcpy(sites[j].k, k, sizeof k);
      si = j;
      break;
    }
    if (!memcmp(sites[j].k, k, sizeof k)) { si = j; break; }
  }
  if (si >= 0) {
    struct site *s = &sites[si];
    s->calls++;
    s->total += sz;
    s->alive += sz;
    if (s->alive > s->peak) s->peak = s->alive;
    unsigned j = live_slot(p);
    for (unsigned i = 0; i < NLIVE; i++, j = (j + 1) & (NLIVE - 1))
      if (!live[j].p) { live[j].p = p; live[j].site = si; live[j].sz = sz; break; }
  }
  g_alive += sz;
  if (g_alive > g_peak) g_peak = g_alive;
  pthread_mutex_unlock(&mu);
}

static void untrack(void *p) {
  pthread_mutex_lock(&mu);
  unsigned j = live_slot(p);
  for (unsigned i = 0; i < NLIVE; i++, j = (j + 1) & (NLIVE - 1)) {
    if (!live[j].p) break;
    if (live[j].p == p) {
      sites[live[j].site].alive -= live[j].sz;
      g_alive -= live[j].sz;
      live[j].p = (void *)-1; /* tombstone */
      break;
    }
  }
  pthread_mutex_unlock(&mu);
}

static void small_acc(size_t sz) {
  int b = 0;
  size_t v = sz;
  while (v >>= 1) b++;
  __atomic_add_fetch(&small_bytes[b], (long long)sz, __ATOMIC_RELAXED);
  __atomic_add_fetch(&small_count[b], 1, __ATOMIC_RELAXED);
}

static void frame_name(void *a, char *out, size_t sz) {
  Dl_info di;
  if (a && dladdr(a, &di) && di.dli_sname)
    snprintf(out, sz, "%s", di.dli_sname);
  else if (a && dladdr(a, &di) && di.dli_fname) {
    const char *b = strrchr(di.dli_fname, '/');
    snprintf(out, sz, "%s+0x%lx", b ? b + 1 : di.dli_fname,
             (unsigned long)((char *)a - (char *)di.dli_fbase));
  } else
    snprintf(out, sz, "?");
}

static void report(void) {
  fprintf(stderr, "==== memprof pid %d: global peak %lld MB ====\n",
          (int)getpid(), g_peak >> 20);
  fprintf(stderr, "%-10s %-10s %-10s %-8s  %s\n", "peakMB", "totalMB",
          "aliveMB", "calls", "site (outer<-inner)");
  for (int rank = 0; rank < 25; rank++) {
    struct site *best = 0;
    for (int i = 0; i < NSITE; i++)
      if (sites[i].calls && (!best || sites[i].peak > best->peak))
        best = &sites[i];
    if (!best || best->peak < (long long)min_big) break;
    char f0[100], f1[100], f2[100];
    frame_name(best->k[0], f0, sizeof f0);
    frame_name(best->k[1], f1, sizeof f1);
    frame_name(best->k[2], f2, sizeof f2);
    fprintf(stderr, "%-10.1f %-10.1f %-10.1f %-8ld  %s <- %s <- %s\n",
            best->peak / 1048576.0, best->total / 1048576.0,
            best->alive / 1048576.0, best->calls, f0, f1, f2);
    best->peak = -1; /* consume */
  }
  long long sb = 0, sc = 0;
  for (int b = 0; b < 48; b++) { sb += small_bytes[b]; sc += small_count[b]; }
  fprintf(stderr, "small (<%zu B): %lld MB across %lld allocations\n",
          min_big, sb >> 20, sc);
}

void *malloc(size_t sz) {
  if (!real_malloc) {
    if (!real_calloc && bootn + sz < sizeof boot) { /* dlsym re-entry */
      void *p = boot + bootn;
      bootn += (sz + 15) & ~(size_t)15;
      return p;
    }
    init_real();
  }
  void *p = real_malloc(sz);
  if (p && !inhook) {
    inhook = 1;
    static int atreg;
    if (!atreg) { atreg = 1; atexit(report); }
    if (sz >= min_big) track(p, sz);
    else small_acc(sz);
    inhook = 0;
  }
  return p;
}

void *calloc(size_t n, size_t sz) {
  if (!real_calloc) {
    if (bootn + n * sz < sizeof boot) { /* dlsym calls calloc */
      void *p = boot + bootn;
      bootn += (n * sz + 15) & ~(size_t)15;
      memset(p, 0, n * sz);
      return p;
    }
    init_real();
  }
  void *p = real_calloc(n, sz);
  if (p && !inhook) {
    inhook = 1;
    if (n * sz >= min_big) track(p, n * sz);
    else small_acc(n * sz);
    inhook = 0;
  }
  return p;
}

void *realloc(void *old, size_t sz) {
  if (!real_realloc) init_real();
  if (old && !inhook) { inhook = 1; untrack(old); inhook = 0; }
  void *p = real_realloc(old, sz);
  if (p && !inhook) {
    inhook = 1;
    if (sz >= min_big) track(p, sz);
    else small_acc(sz);
    inhook = 0;
  }
  return p;
}

void free(void *p) {
  if (!p) return;
  if ((char *)p >= boot && (char *)p < boot + sizeof boot) return;
  if (!real_free) init_real();
  if (!inhook) { inhook = 1; untrack(p); inhook = 0; }
  real_free(p);
}
