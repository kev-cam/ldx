/* mpi_count.c — LD_PRELOAD PMPI profiling shim with caller-module attribution.
 *
 * Counts calls, payload bytes, and wall time inside each wrapped MPI function,
 * attributing every call to the shared object that made it (return-address ->
 * dladdr, cached). This measures (a) the total comm the Xyce shm layer must
 * replace and (b) how much traffic bypasses the Communicator/Epetra_Comm
 * vtable seams (calls from libaztecoo/libXyceLib/libzoltan rather than
 * libepetra).
 *
 * Build:  mpicc -O2 -shared -fPIC -o libmpicount.so mpi_count.c -ldl
 * Use:    mpirun -x LD_PRELOAD=$PWD/libmpicount.so -np 4 Xyce deck.cir
 * Output: per-rank report to /tmp/mpicount.rank<N>.txt; rank 0 also to stderr.
 *         Set MPICOUNT_PREFIX to change the output path prefix.
 *
 * Xyce runs MPI_THREAD_SINGLE, so counters are deliberately unlocked.
 */
#define _GNU_SOURCE
#include <mpi.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

enum {
  F_Allreduce, F_Reduce, F_Bcast, F_Barrier, F_Scan,
  F_Allgather, F_Allgatherv, F_Gather, F_Gatherv,
  F_Scatter, F_Scatterv, F_Alltoall, F_Alltoallv,
  F_Send, F_Rsend, F_Isend, F_Irsend, F_Recv, F_Irecv,
  F_Sendrecv, F_Wait, F_Waitall, F_Waitany,
  F_Probe, F_Iprobe, F_Pack, F_Unpack,
  F_Comm_dup, F_Comm_split, F_Comm_create,
  NFN
};
static const char *fname[NFN] = {
  "Allreduce", "Reduce", "Bcast", "Barrier", "Scan",
  "Allgather", "Allgatherv", "Gather", "Gatherv",
  "Scatter", "Scatterv", "Alltoall", "Alltoallv",
  "Send", "Rsend", "Isend", "Irsend", "Recv", "Irecv",
  "Sendrecv", "Wait", "Waitall", "Waitany",
  "Probe", "Iprobe", "Pack", "Unpack",
  "Comm_dup", "Comm_split", "Comm_create",
};

#define NMOD 64
static char modname[NMOD][64];
static int nmod;

typedef struct { uint64_t calls, bytes; double secs; } cell_t;
static cell_t stat_[NFN][NMOD];

/* return-address -> module cache (dladdr is too slow to run per call) */
#define RASZ 8192
static struct { void *ra; int mod; } racache[RASZ];

static int intern_mod(const char *path) {
  const char *b = strrchr(path, '/');
  b = b ? b + 1 : path;
  for (int i = 0; i < nmod; i++)
    if (!strncmp(modname[i], b, 63)) return i;
  if (nmod >= NMOD) return NMOD - 1;
  strncpy(modname[nmod], b, 63);
  return nmod++;
}

static int mod_of(void *ra) {
  unsigned h = (unsigned)(((uintptr_t)ra >> 4) & (RASZ - 1));
  if (racache[h].ra == ra) return racache[h].mod;
  Dl_info di;
  int m = (dladdr(ra, &di) && di.dli_fname) ? intern_mod(di.dli_fname)
                                            : intern_mod("??");
  racache[h].ra = ra;
  racache[h].mod = m;
  return m;
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + 1e-9 * t.tv_nsec;
}

/* MPICOUNT_SITES=1: per-call-site census. Keyed on a 3-frame call chain so
 * the same MPI function is split by semantic caller (orthogonalization dot
 * vs status-test norm vs step control). backtrace() costs ~1-2us/call —
 * census runs only. */
#define NSITE 4096
static struct site { void *k[3]; uint64_t calls; int fn; } sites[NSITE];
static int use_sites;

static void site_acc(int fn) {
  void *bt[6];
  int n = backtrace(bt, 6);
  void *k[3] = {n > 2 ? bt[2] : 0, n > 3 ? bt[3] : 0, n > 4 ? bt[4] : 0};
  unsigned h = (unsigned)((((uintptr_t)k[0] >> 4) * 31 +
                           ((uintptr_t)k[1] >> 4)) * 31 +
                          ((uintptr_t)k[2] >> 4)) % NSITE;
  for (int i = 0; i < NSITE; i++) {
    unsigned j = (h + i) % NSITE;
    if (!sites[j].calls) {
      memcpy(sites[j].k, k, sizeof k);
      sites[j].fn = fn;
      sites[j].calls = 1;
      return;
    }
    if (sites[j].fn == fn && !memcmp(sites[j].k, k, sizeof k)) {
      sites[j].calls++;
      return;
    }
  }
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

static void site_report(FILE *f) {
  fprintf(f, "---- top call sites (fn, calls, chain outer<-inner) ----\n");
  for (int rank = 0; rank < 25; rank++) {
    struct site *best = 0;
    for (int i = 0; i < NSITE; i++)
      if (sites[i].calls && (!best || sites[i].calls > best->calls))
        best = &sites[i];
    if (!best) break;
    char f0[128], f1[128], f2[128];
    frame_name(best->k[0], f0, sizeof f0);
    frame_name(best->k[1], f1, sizeof f1);
    frame_name(best->k[2], f2, sizeof f2);
    fprintf(f, "%-10s %10llu  %s <- %s <- %s\n", fname[best->fn],
            (unsigned long long)best->calls, f0, f1, f2);
    best->calls = 0;
  }
}

static double wall0;

static void acc(int fn, void *ra, uint64_t bytes, double secs) {
  cell_t *c = &stat_[fn][mod_of(ra)];
  c->calls++;
  c->bytes += bytes;
  c->secs += secs;
  if (use_sites) site_acc(fn);
}

static uint64_t tbytes(int count, MPI_Datatype dt) {
  int ts = 0;
  PMPI_Type_size(dt, &ts);
  return (uint64_t)(count > 0 ? count : 0) * (uint64_t)ts;
}

/* ---- wrappers ---------------------------------------------------------- */

#define TIMED(fncode, bytes, call)                                           \
  do {                                                                       \
    double t_ = now();                                                       \
    int rc_ = (call);                                                        \
    acc(fncode, __builtin_return_address(0), (bytes), now() - t_);           \
    return rc_;                                                              \
  } while (0)

int MPI_Init(int *argc, char ***argv) {
  int rc = PMPI_Init(argc, argv);
  wall0 = now();
  use_sites = getenv("MPICOUNT_SITES") != 0;
  return rc;
}
int MPI_Init_thread(int *argc, char ***argv, int req, int *prov) {
  int rc = PMPI_Init_thread(argc, argv, req, prov);
  wall0 = now();
  return rc;
}

int MPI_Allreduce(const void *s, void *r, int n, MPI_Datatype dt, MPI_Op op, MPI_Comm c)
{ TIMED(F_Allreduce, tbytes(n, dt), PMPI_Allreduce(s, r, n, dt, op, c)); }

int MPI_Reduce(const void *s, void *r, int n, MPI_Datatype dt, MPI_Op op, int root, MPI_Comm c)
{ TIMED(F_Reduce, tbytes(n, dt), PMPI_Reduce(s, r, n, dt, op, root, c)); }

int MPI_Bcast(void *b, int n, MPI_Datatype dt, int root, MPI_Comm c)
{ TIMED(F_Bcast, tbytes(n, dt), PMPI_Bcast(b, n, dt, root, c)); }

int MPI_Barrier(MPI_Comm c)
{ TIMED(F_Barrier, 0, PMPI_Barrier(c)); }

int MPI_Scan(const void *s, void *r, int n, MPI_Datatype dt, MPI_Op op, MPI_Comm c)
{ TIMED(F_Scan, tbytes(n, dt), PMPI_Scan(s, r, n, dt, op, c)); }

int MPI_Allgather(const void *s, int sn, MPI_Datatype st, void *r, int rn, MPI_Datatype rt, MPI_Comm c)
{ TIMED(F_Allgather, tbytes(sn, st), PMPI_Allgather(s, sn, st, r, rn, rt, c)); }

int MPI_Allgatherv(const void *s, int sn, MPI_Datatype st, void *r, const int *rn, const int *disp, MPI_Datatype rt, MPI_Comm c)
{ TIMED(F_Allgatherv, tbytes(sn, st), PMPI_Allgatherv(s, sn, st, r, rn, disp, rt, c)); }

int MPI_Gather(const void *s, int sn, MPI_Datatype st, void *r, int rn, MPI_Datatype rt, int root, MPI_Comm c)
{ TIMED(F_Gather, tbytes(sn, st), PMPI_Gather(s, sn, st, r, rn, rt, root, c)); }

int MPI_Gatherv(const void *s, int sn, MPI_Datatype st, void *r, const int *rn, const int *disp, MPI_Datatype rt, int root, MPI_Comm c)
{ TIMED(F_Gatherv, tbytes(sn, st), PMPI_Gatherv(s, sn, st, r, rn, disp, rt, root, c)); }

int MPI_Scatter(const void *s, int sn, MPI_Datatype st, void *r, int rn, MPI_Datatype rt, int root, MPI_Comm c)
{ TIMED(F_Scatter, tbytes(sn, st), PMPI_Scatter(s, sn, st, r, rn, rt, root, c)); }

int MPI_Scatterv(const void *s, const int *sn, const int *disp, MPI_Datatype st, void *r, int rn, MPI_Datatype rt, int root, MPI_Comm c)
{ TIMED(F_Scatterv, tbytes(rn, rt), PMPI_Scatterv(s, sn, disp, st, r, rn, rt, root, c)); }

int MPI_Alltoall(const void *s, int sn, MPI_Datatype st, void *r, int rn, MPI_Datatype rt, MPI_Comm c)
{ TIMED(F_Alltoall, tbytes(sn, st), PMPI_Alltoall(s, sn, st, r, rn, rt, c)); }

int MPI_Alltoallv(const void *s, const int *sn, const int *sd, MPI_Datatype st, void *r, const int *rn, const int *rd, MPI_Datatype rt, MPI_Comm c)
{ TIMED(F_Alltoallv, 0, PMPI_Alltoallv(s, sn, sd, st, r, rn, rd, rt, c)); }

int MPI_Send(const void *b, int n, MPI_Datatype dt, int dest, int tag, MPI_Comm c)
{ TIMED(F_Send, tbytes(n, dt), PMPI_Send(b, n, dt, dest, tag, c)); }

int MPI_Rsend(const void *b, int n, MPI_Datatype dt, int dest, int tag, MPI_Comm c)
{ TIMED(F_Rsend, tbytes(n, dt), PMPI_Rsend(b, n, dt, dest, tag, c)); }

int MPI_Isend(const void *b, int n, MPI_Datatype dt, int dest, int tag, MPI_Comm c, MPI_Request *rq)
{ TIMED(F_Isend, tbytes(n, dt), PMPI_Isend(b, n, dt, dest, tag, c, rq)); }

int MPI_Irsend(const void *b, int n, MPI_Datatype dt, int dest, int tag, MPI_Comm c, MPI_Request *rq)
{ TIMED(F_Irsend, tbytes(n, dt), PMPI_Irsend(b, n, dt, dest, tag, c, rq)); }

int MPI_Recv(void *b, int n, MPI_Datatype dt, int src, int tag, MPI_Comm c, MPI_Status *st)
{ TIMED(F_Recv, tbytes(n, dt), PMPI_Recv(b, n, dt, src, tag, c, st)); }

int MPI_Irecv(void *b, int n, MPI_Datatype dt, int src, int tag, MPI_Comm c, MPI_Request *rq)
{ TIMED(F_Irecv, tbytes(n, dt), PMPI_Irecv(b, n, dt, src, tag, c, rq)); }

int MPI_Sendrecv(const void *sb, int sn, MPI_Datatype st, int dest, int stag,
                 void *rb, int rn, MPI_Datatype rt, int src, int rtag,
                 MPI_Comm c, MPI_Status *status)
{ TIMED(F_Sendrecv, tbytes(sn, st) + tbytes(rn, rt),
        PMPI_Sendrecv(sb, sn, st, dest, stag, rb, rn, rt, src, rtag, c, status)); }

int MPI_Wait(MPI_Request *rq, MPI_Status *st)
{ TIMED(F_Wait, 0, PMPI_Wait(rq, st)); }

int MPI_Waitall(int n, MPI_Request rq[], MPI_Status st[])
{ TIMED(F_Waitall, 0, PMPI_Waitall(n, rq, st)); }

int MPI_Waitany(int n, MPI_Request rq[], int *idx, MPI_Status *st)
{ TIMED(F_Waitany, 0, PMPI_Waitany(n, rq, idx, st)); }

int MPI_Probe(int src, int tag, MPI_Comm c, MPI_Status *st)
{ TIMED(F_Probe, 0, PMPI_Probe(src, tag, c, st)); }

int MPI_Iprobe(int src, int tag, MPI_Comm c, int *flag, MPI_Status *st)
{ TIMED(F_Iprobe, 0, PMPI_Iprobe(src, tag, c, flag, st)); }

int MPI_Pack(const void *in, int n, MPI_Datatype dt, void *out, int outsz, int *pos, MPI_Comm c)
{ TIMED(F_Pack, tbytes(n, dt), PMPI_Pack(in, n, dt, out, outsz, pos, c)); }

int MPI_Unpack(const void *in, int insz, int *pos, void *out, int n, MPI_Datatype dt, MPI_Comm c)
{ TIMED(F_Unpack, tbytes(n, dt), PMPI_Unpack(in, insz, pos, out, n, dt, c)); }

int MPI_Comm_dup(MPI_Comm c, MPI_Comm *out)
{ TIMED(F_Comm_dup, 0, PMPI_Comm_dup(c, out)); }

int MPI_Comm_split(MPI_Comm c, int color, int key, MPI_Comm *out)
{ TIMED(F_Comm_split, 0, PMPI_Comm_split(c, color, key, out)); }

int MPI_Comm_create(MPI_Comm c, MPI_Group g, MPI_Comm *out)
{ TIMED(F_Comm_create, 0, PMPI_Comm_create(c, g, out)); }

/* ---- report ------------------------------------------------------------ */

static void report(FILE *f, int rank, int np, double wall) {
  double mpisecs = 0;
  uint64_t tcalls = 0;
  for (int fn = 0; fn < NFN; fn++)
    for (int m = 0; m < nmod; m++) {
      mpisecs += stat_[fn][m].secs;
      tcalls += stat_[fn][m].calls;
    }
  fprintf(f, "==== mpicount rank %d/%d: wall %.2fs, in-MPI %.2fs (%.1f%%), "
             "%llu calls ====\n",
          rank, np, wall, mpisecs, wall > 0 ? 100.0 * mpisecs / wall : 0,
          (unsigned long long)tcalls);
  fprintf(f, "%-11s %12s %12s %10s   %s\n",
          "function", "calls", "MB", "ms", "callers");
  for (int fn = 0; fn < NFN; fn++) {
    cell_t tot = {0, 0, 0};
    for (int m = 0; m < nmod; m++) {
      tot.calls += stat_[fn][m].calls;
      tot.bytes += stat_[fn][m].bytes;
      tot.secs += stat_[fn][m].secs;
    }
    if (!tot.calls) continue;
    fprintf(f, "%-11s %12llu %12.3f %10.1f   ", fname[fn],
            (unsigned long long)tot.calls, tot.bytes / 1e6, tot.secs * 1e3);
    /* top 3 calling modules; destructive select is fine, report runs once */
    for (int k = 0; k < 3; k++) {
      int best = -1;
      uint64_t bc = 0;
      for (int m = 0; m < nmod; m++)
        if (stat_[fn][m].calls > bc) { bc = stat_[fn][m].calls; best = m; }
      if (best < 0) break;
      fprintf(f, "%s%s:%.0f%%", k ? ", " : "", modname[best],
              100.0 * bc / tot.calls);
      stat_[fn][best].calls = 0;
    }
    fprintf(f, "\n");
  }
}

int MPI_Finalize(void) {
  int rank = 0, np = 1;
  PMPI_Comm_rank(MPI_COMM_WORLD, &rank);
  PMPI_Comm_size(MPI_COMM_WORLD, &np);
  double wall = now() - wall0;

  const char *pfx = getenv("MPICOUNT_PREFIX");
  if (!pfx) pfx = "/tmp/mpicount";
  char path[256];
  snprintf(path, sizeof path, "%s.rank%d.txt", pfx, rank);
  FILE *f = fopen(path, "w");
  if (f) {
    report(f, rank, np, wall); /* destructive: single pass only */
    if (use_sites) site_report(f); /* also destructive */
    fclose(f);
    if (rank == 0) { /* mirror rank 0's file to stderr */
      f = fopen(path, "r");
      if (f) {
        char line[512];
        while (fgets(line, sizeof line, f)) fputs(line, stderr);
        fclose(f);
      }
    }
  }
  return PMPI_Finalize();
}
