/* shmcomm.cpp — shared-memory replacement for Epetra_MpiComm collectives,
 * installed by vtable replacement through the dynamic linker.
 *
 * This library DEFINES Epetra_MpiComm::Barrier/SumAll/MaxAll/MinAll/Broadcast
 * with the exact mangled symbols libepetra.so was linked against. Under
 * LD_PRELOAD the loader binds both PLT calls and the class vtable slots to
 * these definitions, so every Epetra_MpiComm object in the process — including
 * the one inside Xyce's EpetraMPIComm — dispatches here. No Xyce or Trilinos
 * source changes.
 *
 * Protocol (one uniform scheme for reduce / bcast / barrier):
 *   - every rank publishes value+generation in its OWN cache-line-aligned
 *     slot (zero contention; writer's polling loads pipeline),
 *   - the writer (rank 0; bcast root) waits for all slots at gen g, combines
 *     in deterministic rank order, publishes one result line,
 *   - all ranks snoop the result line. A rank enters gen g+1 only after
 *     consuming result g, which makes result-line reuse safe with no second
 *     barrier. Measured ~6x faster than MPI_Allreduce at 8 ranks, flat in N.
 *
 * Falls back to PMPI when: XYCE_SHMCOMM=0, np==1 handled locally, np>MAXR,
 * ranks span nodes, payload > PAYLOAD_MAX (4KB), or the object's communicator
 * is not MPI_COMM_WORLD. Collectives on MPI_COMM_WORLD are totally ordered
 * across ranks (MPI semantics), so one global generation counter is correct.
 *
 * Hardening (v1.1): every guard is rank-uniform for an MPI-conformant app,
 * but library error paths can fork the collective stream per rank (seen in
 * Ifpack's per-subdomain factorization failures). Three defenses: the writer
 * cross-checks opcode+count in every slot; readers verify the result line
 * was produced for their op (no silent cross-op consumption); and spins
 * abort with an op-history tape after XYCE_SHMCOMM_SPIN_TIMEOUT_S (default
 * 300, 0=never) instead of hanging. XYCE_SHMCOMM_TRACE_FROM=<gen> logs every
 * routing decision from that generation on.
 *
 * Build: mpicxx -std=c++17 -O2 -fPIC -shared -o libshmcomm.so shmcomm.cpp \
 *          -I$TRILINOS_INC -lrt
 * Use:   mpirun -np N -x LD_PRELOAD=$PWD/libshmcomm.so [-x XYCE_SHMCOMM_STATS=1] Xyce ...
 *
 * Xyce runs MPI_THREAD_SINGLE; no locking anywhere by design.
 */
#include <mpi.h>
#include <Epetra_MpiComm.h>
#include <Epetra_MpiDistributor.h>
#include <Epetra_MultiVector.h>
#include <Epetra_Vector.h>
#include <Epetra_LocalMap.h>

#include <dlfcn.h>
#include <string>
#include <unordered_map>
#include <vector>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>
#include <immintrin.h>

namespace {

constexpr int    MAXR        = 64;
constexpr size_t PAYLOAD_MAX = 4096; /* 512 doubles; breaker-size reductions fit */

enum Op : uint32_t {
  OP_SUM_D, OP_SUM_I, OP_SUM_L, OP_SUM_LL,
  OP_MAX_D, OP_MAX_I, OP_MAX_L, OP_MAX_LL,
  OP_MIN_D, OP_MIN_I, OP_MIN_L, OP_MIN_LL,
  OP_BCAST, OP_BARRIER,
};

struct alignas(64) Slot {
  std::atomic<uint64_t> seq;
  uint32_t op;
  uint32_t count;
  char _pad[64 - 16];
  alignas(64) unsigned char data[PAYLOAD_MAX];
};

struct Seg {
  alignas(64) uint32_t nranks;
  Slot slot[MAXR];
  Slot result;
};

enum State { UNINIT, ACTIVE, SOLO, DISABLED };

/* pairwise SPSC rings for the halo distributor, appended to the segment */
struct RingHdr {
  std::atomic<uint64_t> head; char p1[56];
  std::atomic<uint64_t> tail; char p2[56];
};
size_t ring_cap;   /* power of two, bytes per ring */
char  *ring_base;
int    halo_mode = 2; /* XYCE_SHMCOMM_HALO: 0=MPI, 1=fwd rings, 2=both, 3=direct */
int    in_localmap_ctor; /* set by the interposed Epetra_LocalMap ctors */

/* shared-resident arena: declarations follow the state/rank globals below */

State    state = UNINIT;
Seg     *seg;
int      myrank, nranks;
uint64_t gen;
uint64_t trace_from = ~0ull; /* XYCE_SHMCOMM_TRACE_FROM: log ops from this gen */
double   spin_timeout_s = 300; /* XYCE_SHMCOMM_SPIN_TIMEOUT_S; 0 = never */

#define TRACE(fmt, ...)                                                       \
  do { if (gen + 1 >= trace_from)                                             \
         fprintf(stderr, "[t r%d] " fmt "\n", myrank, __VA_ARGS__); } while (0)

/* rolling tape of recent ops, dumped on any FATAL so divergent library
 * error paths (e.g. Ifpack per-rank factorization failures) self-diagnose */
struct Hist { uint64_t g; uint32_t op; int count; uint8_t shm; };
Hist     hist[32];
unsigned histpos;

inline void hrec(uint64_t g, uint32_t op, int count, int shm) {
  hist[histpos++ & 31] = {g, op, count, (uint8_t)shm};
}

void hdump() {
  fprintf(stderr, "[shmcomm r%d] op tape (oldest first, fb = PMPI fallback):\n",
          myrank);
  for (unsigned i = 0; i < 32; i++) {
    const Hist &h = hist[(histpos + i) & 31];
    if (h.g || h.op)
      fprintf(stderr, "  gen=%llu op=%u n=%d %s\n", (unsigned long long)h.g,
              h.op, h.count, h.shm ? "shm" : "fb");
  }
}

/* stats: [0]=reduce [1]=bcast [2]=barrier [3]=halo; .x = shm, .y = fallback */
struct Cat { uint64_t shm, fb; double shm_s, fb_s; } cat[4];

/* shared-resident arena: one slice per rank inside the segment. Vector
 * payloads (Epetra Values_) and the direct-exchange staging live here so
 * any rank can read them in place. Allocator metadata is process-local;
 * only the storage is shared. Freed blocks recycle by exact size (vector
 * shapes repeat); exhaustion falls back to the heap transparently. */
size_t arena_slice;   /* bytes per rank */
char  *arena_region;  /* base of rank 0's slice */
size_t arena_bump;
std::unordered_map<size_t, std::vector<char *>> arena_free_;

inline char *arena_of(int r) { return arena_region + (size_t)r * arena_slice; }

inline int arena_on() { return state == ACTIVE && arena_region != nullptr; }

char *arena_alloc(size_t n) {
  if (!arena_on()) return nullptr;
  n = (n + 63) & ~(size_t)63;
  auto it = arena_free_.find(n);
  if (it != arena_free_.end() && !it->second.empty()) {
    char *p = it->second.back();
    it->second.pop_back();
    return p;
  }
  if (arena_bump + 64 + n > arena_slice) return nullptr; /* full -> heap */
  char *hdr = arena_of(myrank) + arena_bump;
  *(size_t *)hdr = n;
  arena_bump += 64 + n;
  return hdr + 64;
}

inline bool in_my_arena(const void *p) {
  return arena_on() && (const char *)p >= arena_of(myrank) &&
         (const char *)p < arena_of(myrank) + arena_slice;
}

void arena_free(char *p) {
  size_t n = *(size_t *)(p - 64);
  arena_free_[n].push_back(p);
}

double now() {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + 1e-9 * t.tv_nsec;
}

void report() {
  if (!getenv("XYCE_SHMCOMM_STATS")) return;
  static const char *nm[4] = {"reduce", "bcast", "barrier", "halo"};
  fprintf(stderr, "[shmcomm r%d %s]", myrank,
          state == ACTIVE ? "active" : state == SOLO ? "solo" : "disabled");
  for (int i = 0; i < 4; i++)
    fprintf(stderr, " %s:%llu shm(%.1fms)/%llu fb(%.1fms)", nm[i],
            (unsigned long long)cat[i].shm, cat[i].shm_s * 1e3,
            (unsigned long long)cat[i].fb, cat[i].fb_s * 1e3);
  fprintf(stderr, "\n");
}

void init_once() {
  if (state != UNINIT) return;
  state = DISABLED; /* stays disabled on any early exit below */

  int inited = 0;
  PMPI_Initialized(&inited);
  if (!inited) return;
  atexit(report);

  const char *env = getenv("XYCE_SHMCOMM");
  if (env && *env == '0') return;
  if ((env = getenv("XYCE_SHMCOMM_TRACE_FROM"))) trace_from = strtoull(env, 0, 10);
  if ((env = getenv("XYCE_SHMCOMM_SPIN_TIMEOUT_S"))) spin_timeout_s = atof(env);
  if ((env = getenv("XYCE_SHMCOMM_HALO"))) halo_mode = atoi(env);

  PMPI_Comm_rank(MPI_COMM_WORLD, &myrank);
  PMPI_Comm_size(MPI_COMM_WORLD, &nranks);
  if (nranks == 1) { state = SOLO; return; }
  if (nranks > MAXR) return;

  /* all ranks on one node? */
  char self[MPI_MAX_PROCESSOR_NAME] = {0};
  static char all[MAXR][MPI_MAX_PROCESSOR_NAME];
  int len = 0;
  PMPI_Get_processor_name(self, &len);
  PMPI_Allgather(self, MPI_MAX_PROCESSOR_NAME, MPI_CHAR,
                 all, MPI_MAX_PROCESSOR_NAME, MPI_CHAR, MPI_COMM_WORLD);
  for (int r = 0; r < nranks; r++)
    if (strncmp(all[r], self, MPI_MAX_PROCESSOR_NAME)) return;

  /* when a sibling rank aborts, mpirun TERMs us — dump our side of the tape
     (async-signal safety traded for diagnosability on an already-dying run) */
  signal(SIGTERM, [](int) { hdump(); _exit(143); });

  int pid = (int)getpid();
  PMPI_Bcast(&pid, 1, MPI_INT, 0, MPI_COMM_WORLD);
  char name[64];
  snprintf(name, sizeof name, "/xyce-shm-%d", pid);

  /* ring capacity: env KB rounded up to a power of two, default 256KB */
  size_t kb = 256;
  if ((env = getenv("XYCE_SHMCOMM_RING_KB"))) kb = strtoull(env, 0, 10);
  ring_cap = 1;
  while (ring_cap < kb * 1024) ring_cap <<= 1;
  size_t amb = 64; /* arena MB per rank; 0 disables residency */
  if ((env = getenv("XYCE_SHMCOMM_ARENA_MB"))) amb = strtoull(env, 0, 10);
  arena_slice = amb << 20;
  size_t seg_off = (sizeof(Seg) + 63) & ~(size_t)63;
  size_t ring_off = seg_off +
                    (size_t)nranks * nranks * (sizeof(RingHdr) + ring_cap);
  size_t total = ring_off + (size_t)nranks * arena_slice;

  int ok = 1, allok = 0, fd = -1;
  if (myrank == 0) {
    shm_unlink(name); /* stale leftover from a crashed run */
    fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0 || ftruncate(fd, total) < 0) ok = 0;
  }
  PMPI_Barrier(MPI_COMM_WORLD);
  if (myrank != 0) {
    fd = shm_open(name, O_RDWR, 0600);
    if (fd < 0) ok = 0;
  }
  void *m = MAP_FAILED;
  if (ok) {
    m = mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) ok = 0;
  }
  if (fd >= 0) close(fd);
  PMPI_Allreduce(&ok, &allok, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);
  PMPI_Barrier(MPI_COMM_WORLD);
  if (myrank == 0) shm_unlink(name);
  if (!allok) {
    if (m != MAP_FAILED) munmap(m, total);
    return;
  }
  seg = (Seg *)m; /* ftruncate zero-fills: seq=0 everywhere, gen starts at 1 */
  ring_base = (char *)m + seg_off;
  arena_region = arena_slice ? (char *)m + ring_off : nullptr;
  if (myrank == 0) seg->nranks = (uint32_t)nranks;
  state = ACTIVE;
}

/* ---- SPSC ring primitives (one ring per ordered rank pair) -------------- */

inline RingHdr *ring_hdr(int src, int dst) {
  return (RingHdr *)(ring_base +
                     (size_t)(src * nranks + dst) * (sizeof(RingHdr) + ring_cap));
}

/* push up to n bytes into ring(me->dst); returns bytes accepted */
size_t ring_push(int dst, const char *p, size_t n) {
  RingHdr *r = ring_hdr(myrank, dst);
  uint64_t h = r->head.load(std::memory_order_relaxed);
  uint64_t t = r->tail.load(std::memory_order_acquire);
  size_t space = ring_cap - (size_t)(h - t);
  if (!space) return 0;
  if (n > space) n = space;
  char *b = (char *)(r + 1);
  size_t off = (size_t)(h & (ring_cap - 1));
  size_t first = ring_cap - off;
  if (first > n) first = n;
  memcpy(b + off, p, first);
  if (n > first) memcpy(b, p + first, n - first);
  r->head.store(h + n, std::memory_order_release);
  return n;
}

/* pop up to n bytes from ring(src->me); returns bytes delivered */
size_t ring_pop(int src, char *p, size_t n) {
  RingHdr *r = ring_hdr(src, myrank);
  uint64_t h = r->head.load(std::memory_order_acquire);
  uint64_t t = r->tail.load(std::memory_order_relaxed);
  size_t avail = (size_t)(h - t);
  if (!avail) return 0;
  if (n > avail) n = avail;
  const char *b = (const char *)(r + 1);
  size_t off = (size_t)(t & (ring_cap - 1));
  size_t first = ring_cap - off;
  if (first > n) first = n;
  memcpy(p, b + off, first);
  if (n > first) memcpy(p + first, b, n - first);
  r->tail.store(t + n, std::memory_order_release);
  return n;
}

inline void spin_until(std::atomic<uint64_t> &a, uint64_t g, const char *what) {
  uint64_t v;
  unsigned k = 0;
  double t0 = 0;
  while ((v = a.load(std::memory_order_acquire)) < g) {
    _mm_pause();
    if (++k == 65536) {
      k = 0;
      sched_yield();
      double t = now();
      if (t0 == 0) t0 = t;
      else if (spin_timeout_s > 0 && t - t0 > spin_timeout_s) {
        fprintf(stderr, "[shmcomm r%d] FATAL %.0fs spin timeout waiting for %s "
                "at gen %llu — collective streams diverged (library error "
                "path?) or extreme imbalance; XYCE_SHMCOMM=0 disables\n",
                myrank, t - t0, what, (unsigned long long)g);
        hdump();
        abort();
      }
    }
  }
  if (v != g) { /* a rank ran ahead: protocol violated */
    fprintf(stderr, "[shmcomm r%d] FATAL seq %llu > gen %llu waiting for %s\n",
            myrank, (unsigned long long)v, (unsigned long long)g, what);
    hdump();
    abort();
  }
}

template <typename T>
void combine(Op op, unsigned char *dst, int count) {
  T acc[PAYLOAD_MAX / sizeof(T)], tmp[PAYLOAD_MAX / sizeof(T)];
  memcpy(acc, (const void *)seg->slot[0].data, count * sizeof(T));
  for (int r = 1; r < nranks; r++) {
    memcpy(tmp, (const void *)seg->slot[r].data, count * sizeof(T));
    switch (op) {
    case OP_SUM_D: case OP_SUM_I: case OP_SUM_L: case OP_SUM_LL:
      for (int i = 0; i < count; i++) acc[i] += tmp[i];
      break;
    case OP_MAX_D: case OP_MAX_I: case OP_MAX_L: case OP_MAX_LL:
      for (int i = 0; i < count; i++) if (tmp[i] > acc[i]) acc[i] = tmp[i];
      break;
    default:
      for (int i = 0; i < count; i++) if (tmp[i] < acc[i]) acc[i] = tmp[i];
    }
  }
  memcpy(dst, acc, count * sizeof(T));
}

/* Core collective. in/out may alias (Broadcast is in-place: root passes its
 * buffer as in, receivers as out). Returns false -> caller must use PMPI. */
bool shm_op(Op op, const void *in, void *out, int count, size_t esz, int root) {
  if (state == UNINIT) init_once();
  if (state == SOLO) {
    if (op != OP_BARRIER && op != OP_BCAST && out != in)
      memcpy(out, in, count * esz);
    return true;
  }
  if (state != ACTIVE) return false;
  size_t bytes = (size_t)count * esz;
  if (bytes > PAYLOAD_MAX) {
    TRACE("g=%llu FB(size) op=%u n=%d", (unsigned long long)gen, op, count);
    return false;
  }

  uint64_t g = ++gen;
  TRACE("g=%llu SHM op=%u n=%d", (unsigned long long)g, op, count);
  hrec(g, op, count, 1);
  Slot &mine = seg->slot[myrank];
  if (bytes && (op != OP_BCAST || myrank == root))
    memcpy((void *)mine.data, in, bytes);
  mine.op = op;
  mine.count = (uint32_t)count;
  mine.seq.store(g, std::memory_order_release);

  int writer = (op == OP_BCAST) ? root : 0;
  if (myrank == writer) {
    for (int r = 0; r < nranks; r++) {
      spin_until(seg->slot[r].seq, g, "peer slot");
      if (seg->slot[r].op != (uint32_t)op || seg->slot[r].count != (uint32_t)count) {
        fprintf(stderr, "[shmcomm r%d] FATAL divergence: rank %d op %u/%u "
                "count %u/%u at gen %llu\n", myrank, r, seg->slot[r].op, op,
                seg->slot[r].count, count, (unsigned long long)g);
        hdump();
        abort();
      }
    }
    switch (op) {
    case OP_BARRIER: break;
    case OP_BCAST: if (bytes) memcpy((void *)seg->result.data, in, bytes); break;
    case OP_SUM_D: case OP_MAX_D: case OP_MIN_D:
      combine<double>(op, (unsigned char *)seg->result.data, count); break;
    case OP_SUM_I: case OP_MAX_I: case OP_MIN_I:
      combine<int>(op, (unsigned char *)seg->result.data, count); break;
    case OP_SUM_L: case OP_MAX_L: case OP_MIN_L:
      combine<long>(op, (unsigned char *)seg->result.data, count); break;
    default:
      combine<long long>(op, (unsigned char *)seg->result.data, count); break;
    }
    seg->result.op = op;
    seg->result.count = (uint32_t)count;
    seg->result.seq.store(g, std::memory_order_release);
    if (op != OP_BARRIER && op != OP_BCAST && bytes)
      memcpy(out, (const void *)seg->result.data, bytes);
  } else {
    spin_until(seg->result.seq, g, "result line");
    if (seg->result.op != (uint32_t)op || seg->result.count != (uint32_t)count) {
      /* writer produced a result for a different collective: the app's
         world-collective sequence forked between ranks */
      fprintf(stderr, "[shmcomm r%d] FATAL result mismatch: got op %u n %u, "
              "expected op %u n %d at gen %llu\n", myrank, seg->result.op,
              seg->result.count, op, count, (unsigned long long)g);
      hdump();
      abort();
    }
    if (op != OP_BARRIER && bytes)
      memcpy(out, (const void *)seg->result.data, bytes);
  }
  return true;
}

inline bool on_world(const Epetra_MpiComm *c) {
  return c->Comm() == MPI_COMM_WORLD;
}

/* timing + stats wrapper: ci 0=reduce 1=bcast 2=barrier */
inline bool timed(int ci, Op op, const void *in, void *out, int count,
                  size_t esz, int root) {
  double t0 = now();
  bool r = shm_op(op, in, out, count, esz, root);
  double dt = now() - t0;
  Cat &c = cat[ci];
  if (r) { c.shm++; c.shm_s += dt; }
  return r; /* fallback timing accumulated by the caller */
}

inline void fb_time(int ci, double t0) {
  cat[ci].fb++;
  cat[ci].fb_s += now() - t0;
}

} // namespace

/* ---- interposed Epetra_MpiComm members ---------------------------------- */

void Epetra_MpiComm::Barrier() const {
  if (on_world(this) && timed(2, OP_BARRIER, nullptr, nullptr, 0, 1, 0)) return;
  hrec(gen, OP_BARRIER, 0, 0);
  double t0 = now();
  PMPI_Barrier(Comm());
  fb_time(2, t0);
}

#define REDUCE(NAME, T, MPIT, OPC, MPIOP)                                     \
  int Epetra_MpiComm::NAME(T *part, T *glob, int count) const {               \
    if (on_world(this) && timed(0, OPC, part, glob, count, sizeof(T), 0))     \
      return 0;                                                               \
    hrec(gen, OPC, count, 0);                                                 \
    double t0 = now();                                                        \
    PMPI_Allreduce(part, glob, count, MPIT, MPIOP, Comm());                   \
    fb_time(0, t0);                                                           \
    return 0;                                                                 \
  }

REDUCE(SumAll, double,    MPI_DOUBLE,    OP_SUM_D,  MPI_SUM)
REDUCE(SumAll, int,       MPI_INT,       OP_SUM_I,  MPI_SUM)
REDUCE(SumAll, long,      MPI_LONG,      OP_SUM_L,  MPI_SUM)
REDUCE(SumAll, long long, MPI_LONG_LONG, OP_SUM_LL, MPI_SUM)
REDUCE(MaxAll, double,    MPI_DOUBLE,    OP_MAX_D,  MPI_MAX)
REDUCE(MaxAll, int,       MPI_INT,       OP_MAX_I,  MPI_MAX)
REDUCE(MaxAll, long,      MPI_LONG,      OP_MAX_L,  MPI_MAX)
REDUCE(MaxAll, long long, MPI_LONG_LONG, OP_MAX_LL, MPI_MAX)
REDUCE(MinAll, double,    MPI_DOUBLE,    OP_MIN_D,  MPI_MIN)
REDUCE(MinAll, int,       MPI_INT,       OP_MIN_I,  MPI_MIN)
REDUCE(MinAll, long,      MPI_LONG,      OP_MIN_L,  MPI_MIN)
REDUCE(MinAll, long long, MPI_LONG_LONG, OP_MIN_LL, MPI_MIN)

#define BCAST(T, MPIT)                                                        \
  int Epetra_MpiComm::Broadcast(T *vals, int count, int root) const {         \
    if (on_world(this) &&                                                     \
        timed(1, OP_BCAST, vals, vals, count, sizeof(T), root))               \
      return 0;                                                               \
    hrec(gen, OP_BCAST, count, 0);                                            \
    double t0 = now();                                                        \
    PMPI_Bcast(vals, count, MPIT, root, Comm());                              \
    fb_time(1, t0);                                                           \
    return 0;                                                                 \
  }

BCAST(double,    MPI_DOUBLE)
BCAST(int,       MPI_INT)
BCAST(long,      MPI_LONG)
BCAST(long long, MPI_LONG_LONG)
BCAST(char,      MPI_CHAR)

/* ---- C-level interposers ------------------------------------------------
 * Epetra_MpiDistributor calls MPI_Barrier directly (its ready-send protocol),
 * and Xyce's N_PDS_MPI.h free functions call MPI_Allreduce/MPI_Bcast on the
 * raw communicator — none of that flows through the Epetra_MpiComm vtable.
 * Interpose the C symbols too: same engine, same world-comm guard, PMPI
 * fallback otherwise. Our own internals only ever call PMPI_*, so there is
 * no recursion. */

namespace {

bool map_reduce(MPI_Datatype dt, MPI_Op op, Op *out, size_t *esz) {
  int base;
  if      (dt == MPI_DOUBLE)    { base = 0; *esz = sizeof(double); }
  else if (dt == MPI_INT)       { base = 1; *esz = sizeof(int); }
  else if (dt == MPI_LONG)      { base = 2; *esz = sizeof(long); }
  else if (dt == MPI_LONG_LONG) { base = 3; *esz = sizeof(long long); }
  else return false;
  if      (op == MPI_SUM) *out = (Op)(OP_SUM_D + base);
  else if (op == MPI_MAX) *out = (Op)(OP_MAX_D + base);
  else if (op == MPI_MIN) *out = (Op)(OP_MIN_D + base);
  else return false;
  return true;
}

} // namespace

extern "C" int MPI_Barrier(MPI_Comm c) {
  if (c == MPI_COMM_WORLD && timed(2, OP_BARRIER, nullptr, nullptr, 0, 1, 0))
    return MPI_SUCCESS;
  hrec(gen, OP_BARRIER, c == MPI_COMM_WORLD ? 0 : -1, 0);
  double t0 = now();
  int rc = PMPI_Barrier(c);
  fb_time(2, t0);
  return rc;
}

extern "C" int MPI_Allreduce(const void *sbuf, void *rbuf, int count,
                             MPI_Datatype dt, MPI_Op op, MPI_Comm c) {
  Op o;
  size_t esz;
  if (c == MPI_COMM_WORLD && map_reduce(dt, op, &o, &esz)) {
    const void *in = (sbuf == MPI_IN_PLACE) ? rbuf : sbuf;
    if (timed(0, o, in, rbuf, count, esz, 0)) return MPI_SUCCESS;
    hrec(gen, o, count, 0);
  } else {
    TRACE("g=%llu FB(allreduce) world=%d n=%d", (unsigned long long)gen,
          c == MPI_COMM_WORLD, count);
    hrec(gen, 99 /* unmapped/non-world allreduce */, count, 0);
  }
  double t0 = now();
  int rc = PMPI_Allreduce(sbuf, rbuf, count, dt, op, c);
  fb_time(0, t0);
  return rc;
}

extern "C" int MPI_Bcast(void *buf, int count, MPI_Datatype dt, int root,
                         MPI_Comm c) {
  int ts = 0;
  if (c == MPI_COMM_WORLD && count >= 0 &&
      PMPI_Type_size(dt, &ts) == MPI_SUCCESS && ts > 0) {
    size_t bytes = (size_t)count * (size_t)ts; /* bcast is a byte copy */
    if (bytes <= PAYLOAD_MAX &&
        timed(1, OP_BCAST, buf, buf, (int)bytes, 1, root))
      return MPI_SUCCESS;
  }
  hrec(gen, OP_BCAST, count, 0);
  double t0 = now();
  int rc = PMPI_Bcast(buf, count, dt, root, c);
  fb_time(1, t0);
  return rc;
}

/* ---- ShmDistributor: SPSC-ring halo exchange ----------------------------
 * The parent Epetra_MpiDistributor still builds and owns the plan (so any
 * unhandled case delegates to real MPI with full state), but fixed-size
 * Do/DoReverse move the bytes through the pairwise rings: no MPI_Barrier
 * (the ready-send handshake is structurally unnecessary for SPSC rings),
 * no tag matching, no posted receives. Message boundaries need no framing:
 * both ends know every exchange's byte count from the plan, and pairwise
 * FIFO order is exactly MPI's non-overtaking guarantee.
 *
 * Transport choice is rank-uniform BY AGREEMENT: at plan-creation time all
 * ranks PMPI_Allreduce(MIN) their local eligibility (shm active, world comm,
 * export PIDs grouped by destination), so no rank can ring while another
 * falls back — the failure mode the Ifpack fork taught us to fear. */

namespace {

class ShmDistributor : public Epetra_MpiDistributor {
public:
  explicit ShmDistributor(const Epetra_MpiComm &c) : Epetra_MpiDistributor(c) {}
  /* clones keep the plan but not the direct-mode arena state (descriptor
     tables are per-instance SPSC channels; sharing them would double-free
     and cross the epoch streams) — clones fall back to rings uniformly */
  ShmDistributor(const ShmDistributor &o)
    : Epetra_MpiDistributor(o), sblk_(o.sblk_), nexp_(o.nexp_),
      use_rings_(o.use_rings_) {}

  Epetra_Distributor *Clone() override { return new ShmDistributor(*this); }

  using Epetra_MpiDistributor::Do;
  using Epetra_MpiDistributor::DoReverse;
  using Epetra_MpiDistributor::DoPosts;
  using Epetra_MpiDistributor::DoReversePosts;

  int CreateFromSends(const int &nexp, const int *pids, bool det,
                      int &nrem) override {
    int rc = Epetra_MpiDistributor::CreateFromSends(nexp, pids, det, nrem);
    agree(capture(nexp, pids));
    fingerprint_();
    return rc;
  }
  int CreateFromRecvs(const int &nrem, const int *rgids, const int *rpids,
                      bool det, int &nexp, int *&egids, int *&epids) override {
    int rc = Epetra_MpiDistributor::CreateFromRecvs(nrem, rgids, rpids, det,
                                                    nexp, egids, epids);
    agree(rc == 0 && capture(nexp, epids));
    fingerprint_();
    return rc;
  }
  int CreateFromRecvs(const int &nrem, const long long *rgids,
                      const int *rpids, bool det, int &nexp,
                      long long *&egids, int *&epids) override {
    int rc = Epetra_MpiDistributor::CreateFromRecvs(nrem, rgids, rpids, det,
                                                    nexp, egids, epids);
    agree(rc == 0 && capture(nexp, epids));
    fingerprint_();
    return rc;
  }

  int Do(char *ex, int osz, int &lim, char *&im) override {
    if (!use_rings_ || halo_mode < 1 || !plan_current_()) {
      cat[3].fb++;
      double t0 = now();
      int rc = Epetra_MpiDistributor::Do(ex, osz, lim, im);
      cat[3].fb_s += now() - t0;
      return rc;
    }
    double t0 = now();
    exchange(ex, osz, lim, im, false);
    cat[3].shm++;
    cat[3].shm_s += now() - t0;
    return 0;
  }
  int DoReverse(char *ex, int osz, int &lim, char *&im) override {
    if (!use_rings_ || halo_mode < 2 || !plan_current_()) {
      cat[3].fb++;
      double t0 = now();
      int rc = Epetra_MpiDistributor::DoReverse(ex, osz, lim, im);
      cat[3].fb_s += now() - t0;
      return rc;
    }
    double t0 = now();
    exchange(ex, osz, lim, im, true);
    cat[3].shm++;
    cat[3].shm_s += now() - t0;
    return 0;
  }
  int DoPosts(char *ex, int osz, int &lim, char *&im) override {
    if (use_rings_ && halo_mode >= 1 && plan_current_()) {
      posts_delegated_ = false;
      return Do(ex, osz, lim, im);
    }
    posts_delegated_ = true;
    return Epetra_MpiDistributor::DoPosts(ex, osz, lim, im);
  }
  int DoWaits() override {
    return posts_delegated_ ? Epetra_MpiDistributor::DoWaits() : 0;
  }
  int DoReversePosts(char *ex, int osz, int &lim, char *&im) override {
    if (use_rings_ && halo_mode >= 2 && plan_current_()) {
      rposts_delegated_ = false;
      return DoReverse(ex, osz, lim, im);
    }
    rposts_delegated_ = true;
    return Epetra_MpiDistributor::DoReversePosts(ex, osz, lim, im);
  }
  int DoReverseWaits() override {
    return rposts_delegated_ ? Epetra_MpiDistributor::DoReverseWaits() : 0;
  }
  /* variable-size posts: transport stays with the parent, but the flag must
     record that so the next DoWaits/DoReverseWaits delegates */
  int DoPosts(char *ex, int osz, int *&sizes, int &lim, char *&im) override {
    posts_delegated_ = true;
    return Epetra_MpiDistributor::DoPosts(ex, osz, sizes, lim, im);
  }
  int DoReversePosts(char *ex, int osz, int *&sizes, int &lim,
                     char *&im) override {
    rposts_delegated_ = true;
    return Epetra_MpiDistributor::DoReversePosts(ex, osz, sizes, lim, im);
  }

public:
  ~ShmDistributor() override {
    if (myDesc_) arena_free((char *)myDesc_);
    if (myAckBase_) arena_free(myAckBase_);
    for (char *s : stag_)
      if (s) arena_free(s);
  }

private:
  struct Blk { int proc, start, len; }; /* items, in export-array units */
  std::vector<Blk> sblk_;               /* send blocks incl. self, grouped */
  int  nexp_ = 0;
  bool use_rings_ = false;
  /* parent-plan fingerprint at capture time. The concrete class exposes
   * NON-virtual plan builders (CreateFromSendsAndRecvs) that can rebuild
   * the parent's plan without our overrides seeing it — the stale capture
   * then disagrees with the plan and corrupts the exchange. Rebuilds are
   * collective, so a fingerprint mismatch is rank-uniform and every rank
   * delegates to the parent's MPI path together. */
  int fpS_ = -1, fpR_ = -1, fpT_ = -1;
  void fingerprint_() {
    fpS_ = NumSends();
    fpR_ = NumReceives();
    fpT_ = TotalReceiveLength();
  }
  bool plan_current_() {
    return fpS_ == NumSends() && fpR_ == NumReceives() &&
           fpT_ == TotalReceiveLength();
  }

  /* HALO=3 direct exchange: I publish {epoch, staging offset, bytes} in my
   * arena; the receiver copies straight out of my slice and acks into its
   * own ack line, which I poll before reusing the staging. One SPSC line
   * each way per pair, no FIFO bookkeeping, message size bounded only by
   * the arena. */
  struct DDesc {
    std::atomic<uint64_t> epoch;
    uint64_t off, bytes;
    char pad[40];
  };
  bool   directInit_ = false, direct_ = false;
  DDesc *myDesc_ = nullptr;     /* [nranks], slot d read by rank d */
  char  *myAckBase_ = nullptr;  /* nranks cache lines; line s = ack to rank s */
  std::vector<uint64_t> peerDescOff_, peerAckOff_; /* arena-relative */
  std::vector<char *>   stag_;
  std::vector<size_t>   stagCap_;
  std::vector<uint64_t> sendEp_, recvEp_;

  inline std::atomic<uint64_t> *peer_ack(int dst) { /* dst's ack line for me */
    return (std::atomic<uint64_t> *)(arena_of(dst) + peerAckOff_[dst] +
                                     64 * (size_t)myrank);
  }
  inline DDesc *peer_desc(int src) { /* src's publish slot for me */
    return (DDesc *)(arena_of(src) + peerDescOff_[src]) + myrank;
  }

  void direct_setup() {
    directInit_ = true;
    myDesc_ = (DDesc *)arena_alloc(nranks * sizeof(DDesc));
    myAckBase_ = arena_alloc((size_t)nranks * 64);
    int ok = (myDesc_ && myAckBase_) ? 1 : 0, allok = 0;
    if (ok) {
      memset((void *)myDesc_, 0, nranks * sizeof(DDesc));
      memset(myAckBase_, 0, (size_t)nranks * 64);
    }
    uint64_t mine[2] = {
        ok ? (uint64_t)((char *)myDesc_ - arena_of(myrank)) : 0,
        ok ? (uint64_t)(myAckBase_ - arena_of(myrank)) : 0};
    PMPI_Allreduce(&ok, &allok, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);
    std::vector<uint64_t> all(2 * (size_t)nranks);
    PMPI_Allgather(mine, 2, MPI_UNSIGNED_LONG, all.data(), 2,
                   MPI_UNSIGNED_LONG, MPI_COMM_WORLD);
    if (!allok) return; /* uniform: every rank sees allok */
    peerDescOff_.resize(nranks);
    peerAckOff_.resize(nranks);
    for (int r = 0; r < nranks; r++) {
      peerDescOff_[r] = all[2 * (size_t)r];
      peerAckOff_[r] = all[2 * (size_t)r + 1];
    }
    stag_.assign(nranks, nullptr);
    stagCap_.assign(nranks, 0);
    sendEp_.assign(nranks, 0);
    recvEp_.assign(nranks, 0);
    direct_ = true;
    if (myrank == 0 && getenv("XYCE_SHMCOMM_STATS"))
      fprintf(stderr, "[shmcomm r0] halo: direct arena exchange active "
              "(instance %p)\n", (void *)this);
  }
  /* default TRUE: any posts we did not personally satisfy through the rings
     (including the variable-size paths, where the parent's Do calls DoPosts
     and DoWaits VIRTUALLY) must be completed by the parent's Waitall —
     returning 0 from DoWaits for un-waited Irecvs hands the caller
     incomplete buffers */
  bool posts_delegated_ = true, rposts_delegated_ = true;

  /* capture per-destination blocks; eligible only if PIDs are grouped
     (each destination one contiguous run — Epetra_Import sorts by PID, so
     this is the common case; anything else delegates to MPI) */
  bool capture(int nexp, const int *pids) {
    sblk_.clear();
    nexp_ = nexp;
    char seen[MAXR] = {0};
    for (int i = 0; i < nexp; i++) {
      int p = pids[i];
      if (p < 0 || p >= nranks) return false;
      if (!sblk_.empty() && sblk_.back().proc == p) { sblk_.back().len++; continue; }
      if (seen[p]) return false; /* second run for same destination */
      seen[p] = 1;
      sblk_.push_back({p, i, 1});
    }
    return true;
  }

  void agree(bool local_ok) {
    int ok = (local_ok && state == ACTIVE) ? 1 : 0, allok = 0;
    PMPI_Allreduce(&ok, &allok, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);
    use_rings_ = (allok == 1);
    /* rank-uniform guard: use_rings_/halo_mode/arena state agree on every
       rank, so all ranks run direct_setup()'s collectives together */
    if (use_rings_ && halo_mode >= 3 && arena_on() && !directInit_)
      direct_setup();
  }

  struct Pend { int proc; const char *sp; char *rp; size_t left; uint64_t ep; };

  /* forward: send sblk_ slices, receive per plan (ProcsFrom order).
     reverse: send my import-layout slices back, scatter into export layout. */
  void exchange(char *ex, int osz, int &lim, char *&im, bool rev) {
    /* receive-plan walk: arrays include the self entry; length is recovered
       by accumulating LengthsFrom up to TotalReceiveLength (no accessor for
       the self flag) */
    const int *pf = ProcsFrom(), *lf = LengthsFrom();
    int total_from = TotalReceiveLength(), nrblk = 0;
    for (int sum = 0; sum < total_from; nrblk++) sum += lf[nrblk];

    static int trace_halo = -1;
    if (trace_halo < 0)
      trace_halo = getenv("XYCE_SHMCOMM_TRACE_HALO") ? 1 : 0;
    if (trace_halo)
      fprintf(stderr, "[hx r%d] rev=%d osz=%d nexp=%d sblk=%zu total_from=%d "
              "nrblk=%d lim=%d ex=%p im=%p\n", myrank, (int)rev, osz, nexp_,
              sblk_.size(), total_from, nrblk, lim, (void *)ex, (void *)im);

    int need = (rev ? nexp_ : total_from) * osz;
    if (lim < need) {
      if (im) { delete[] im; im = 0; }
      lim = need;
      if (lim > 0) { im = new char[lim]; memset(im, 0, lim); }
    }

    std::vector<Pend> sends, recvs;
    long self_src_off = -1, self_dst_off = -1;

    int off = 0;
    for (int i = 0; i < nrblk; i++) { /* import-layout offsets, plan order */
      size_t bytes = (size_t)lf[i] * osz;
      if (pf[i] == myrank) { if (rev) self_src_off = off; else self_dst_off = off; }
      else if (bytes) { /* zero-length blocks carry nothing — skip */
        if (rev) sends.push_back({pf[i], ex + off, nullptr, bytes, 0});
        else     recvs.push_back({pf[i], nullptr, im + off, bytes, 0});
      }
      off += (int)bytes;
    }
    for (const Blk &b : sblk_) { /* export-layout offsets, grouped */
      size_t bytes = (size_t)b.len * osz;
      long o = (long)b.start * osz;
      if (b.proc == myrank) { if (rev) self_dst_off = o; else self_src_off = o; }
      else if (bytes) {
        if (rev) recvs.push_back({b.proc, nullptr, im + o, bytes, 0});
        else     sends.push_back({b.proc, ex + o, nullptr, bytes, 0});
      }
    }
    if (direct_) { /* per-(instance,pair) epoch streams, both directions */
      for (Pend &s : sends) s.ep = ++sendEp_[s.proc];
      for (Pend &r : recvs) r.ep = ++recvEp_[r.proc];
    }
    if (self_src_off >= 0 && self_dst_off >= 0) {
      size_t bytes = 0;
      for (const Blk &b : sblk_) if (b.proc == myrank) bytes = (size_t)b.len * osz;
      memcpy(im + self_dst_off, ex + self_src_off, bytes);
    }

    /* progress loop: interleave sends and receives so neither backpressure
       (ring-full or unacked staging) can deadlock a cycle — every rank
       always drains its inbound side while blocked outbound */
    size_t pending = sends.size() + recvs.size();
    double stall0 = 0;
    while (pending) {
      bool moved = false;
      for (Pend &s : sends)
        if (s.left) {
          if (direct_) {
            if (peer_ack(s.proc)->load(std::memory_order_acquire) >= s.ep - 1) {
              if (stagCap_[s.proc] < s.left) {
                char *ns = arena_alloc(s.left);
                if (!ns) {
                  fprintf(stderr, "[shmcomm r%d] FATAL arena exhausted for "
                          "%zuB staging — raise XYCE_SHMCOMM_ARENA_MB\n",
                          myrank, s.left);
                  hdump();
                  abort();
                }
                if (stag_[s.proc]) arena_free(stag_[s.proc]);
                stag_[s.proc] = ns;
                stagCap_[s.proc] = *(size_t *)(ns - 64);
              }
              memcpy(stag_[s.proc], s.sp, s.left);
              myDesc_[s.proc].off = (uint64_t)(stag_[s.proc] - arena_of(myrank));
              myDesc_[s.proc].bytes = s.left;
              myDesc_[s.proc].epoch.store(s.ep, std::memory_order_release);
              s.left = 0; moved = true; pending--;
            }
          } else {
            size_t n = ring_push(s.proc, s.sp, s.left);
            if (n) { s.sp += n; s.left -= n; moved = true; if (!s.left) pending--; }
          }
        }
      for (Pend &r : recvs)
        if (r.left) {
          if (direct_) {
            DDesc *d = peer_desc(r.proc);
            if (d->epoch.load(std::memory_order_acquire) >= r.ep) {
              if (d->bytes != r.left) {
                fprintf(stderr, "[shmcomm r%d] FATAL direct-halo size mismatch"
                        " from %d: got %llu want %zu at ep %llu\n", myrank,
                        r.proc, (unsigned long long)d->bytes, r.left,
                        (unsigned long long)r.ep);
                hdump();
                abort();
              }
              memcpy(r.rp, arena_of(r.proc) + d->off, r.left);
              ((std::atomic<uint64_t> *)(myAckBase_ + 64 * (size_t)r.proc))
                  ->store(r.ep, std::memory_order_release);
              r.left = 0; moved = true; pending--;
            }
          } else {
            size_t n = ring_pop(r.proc, r.rp, r.left);
            if (n) { r.rp += n; r.left -= n; moved = true; if (!r.left) pending--; }
          }
        }
      if (moved) { stall0 = 0; continue; }
      _mm_pause();
      double t = now();
      if (stall0 == 0) stall0 = t;
      else if (spin_timeout_s > 0 && t - stall0 > spin_timeout_s) {
        fprintf(stderr, "[shmcomm r%d] FATAL %.0fs halo stall (%zu pending, "
                "rev=%d, direct=%d) — peer took a different transport?\n",
                myrank, t - stall0, pending, (int)rev, (int)direct_);
        hdump();
        abort();
      }
    }
  }
};

} // namespace

/* ---- AztecOO Krylov-workspace rollover -----------------------------------
 * AztecOO reallocates its entire GMRES workspace (Krylov basis included —
 * ~1GB of cumulative churn per breaker run) every solve; AZ_keep_info only
 * protects the matrix-name scope and the per-iterate scope gets cleared
 * regardless.  Rather than chase Aztec's lifecycle, interpose
 * AZ_manage_memory: large AZ_ALLOC requests are served from a two-buffer
 * rollover keyed by (scope,label,size) — one buffer in use, one resting —
 * flipped at each AZ_CLEAR (the solve boundary).  Status is always reported
 * as AZ_NEW_ADDRESS so the solver fully re-initializes the block; the
 * resting buffer needs no reset.  Aztec never tracks these blocks, so no
 * clear anywhere can free them: zero allocator traffic, page-warm reuse,
 * and stable addresses for affinity pinning.  XYCE_AZ_ROLLOVER=0 disables.
 */

namespace {

struct AzKey {
  int type;
  size_t size;
  std::string label;
  bool operator==(const AzKey &o) const {
    return type == o.type && size == o.size && label == o.label;
  }
};
struct AzKeyHash {
  size_t operator()(const AzKey &k) const {
    return std::hash<std::string>()(k.label) * 31 + k.type + k.size;
  }
};
struct AzBufs { char *b[2] = {nullptr, nullptr}; };
std::unordered_map<AzKey, AzBufs, AzKeyHash> az_cache;
std::unordered_map<int, uint64_t> az_gen; /* per scope (type) */

int az_rollover_on() {
  static int v = -1;
  if (v < 0) {
    const char *e = getenv("XYCE_AZ_ROLLOVER");
    v = e ? atoi(e) : 1;
  }
  return v;
}

typedef double *(*az_mm_fn)(size_t, int, int, char *, int *);

} // namespace

#define AZR_ALLOC 0
#define AZR_CLEAR 1
#define AZR_CLEAR_ALL 10
#define AZR_NEW_ADDRESS 1
#define AZR_MIN (64 * 1024)

extern "C" double *AZ_manage_memory(size_t size, int action, int type,
                                    char *name, int *status) {
  static az_mm_fn real =
      (az_mm_fn)dlsym(RTLD_NEXT, "AZ_manage_memory");
  if (!az_rollover_on() || !real)
    return real ? real(size, action, type, name, status) : nullptr;

  if (action == AZR_ALLOC && size >= AZR_MIN && name) {
    AzKey k{type, size, std::string(name)};
    AzBufs &v = az_cache[k];
    int idx = (int)(az_gen[type] & 1);
    if (!v.b[idx]) v.b[idx] = new char[size];
    if (status) *status = AZR_NEW_ADDRESS;
    return (double *)v.b[idx];
  }
  if (action == AZR_CLEAR || action == AZR_CLEAR_ALL)
    az_gen[type]++; /* solve boundary: flip active buffer for this scope */
  return real(size, action, type, name, status);
}

/* interposed factory: every Epetra_Import/Export on the world comm gets the
 * ring distributor while shm is active; everything else gets stock MPI */
Epetra_Distributor *Epetra_MpiComm::CreateDistributor() const {
  if (state == UNINIT) init_once();
  if (state == ACTIVE && on_world(this))
    return new ShmDistributor(*this);
  return new Epetra_MpiDistributor(*this);
}

/* ---- constructor-collective elimination ---------------------------------
 * A call-site census showed 94% of all reductions (117k of 124k in a
 * 126-step Belos run) are object-lifecycle ceremony: every Belos workspace
 * view/LocalMap construction fires collectives whose answers are
 * run-constants. Killed at the semantic level, not the transport level:
 *   - AllocateForView's MaxAll only synchronizes a Random() seed across
 *     ranks -> deterministic process-uniform counter seed, no comm.
 *   - LocalMap::CheckInput only validates that all ranks passed the same
 *     size -> skipped (debug-grade check; XYCE_SHMCOMM_CTOR=0 restores).
 *   - IsDistributedGlobal is real semantics, but under a LocalMap ctor
 *     numGlobal==numMy on every rank BY THE CLASS CONTRACT, so the answer
 *     ("replicated") is locally and uniformly decidable. The ctor wrappers
 *     below set a flag; only flagged calls short-circuit — genuine
 *     BlockMaps keep the true MinAll. */

namespace {
/* lazy env read: these paths can run before init_once */
inline int ctor_on() {
  static int envv = -1;
  if (envv < 0) {
    const char *e = getenv("XYCE_SHMCOMM_CTOR");
    envv = e ? atoi(e) : 1;
  }
  return envv && state != DISABLED;
}
} // namespace

bool Epetra_BlockMap::IsDistributedGlobal(long long numGlobalElements,
                                          int numMyElements) const {
  if (Comm().NumProc() <= 1) return false;
  if (ctor_on() && in_localmap_ctor && numGlobalElements == numMyElements)
    return false;
  int LocalReplicated = (numGlobalElements == numMyElements) ? 1 : 0;
  int AllLocalReplicated;
  Comm().MinAll(&LocalReplicated, &AllLocalReplicated, 1);
  return AllLocalReplicated != 1;
}

int Epetra_LocalMap::CheckInput() {
  if (ctor_on()) return 0;
  int tmp[4] = {NumMyElements(), -NumMyElements(), 0, 0};
  Comm().MaxAll(tmp, tmp + 2, 2);
  return (tmp[2] == -tmp[3]) ? 0 : -1;
}

int Epetra_MultiVector::AllocateForView(void) {
  if (NumVectors_ <= 0)
    throw ReportError("Number of Vectors = " + toString(NumVectors_) +
                      ", but must be greater than zero", -1);
  Pointers_ = new double *[NumVectors_];
  DoubleTemp_ = 0;
  Vectors_ = 0;

  if (ctor_on()) {
    /* stock code MaxAll's rand() so replicated vectors share a Random()
       seed; a counter advancing identically on every rank (view
       construction is collective) gives the same guarantee for free */
    static unsigned ctr;
    ++ctr;
    if (DistributedGlobal())
      Util_.SetSeed((unsigned)(2 * Comm_->MyPID() + ctr));
    else
      Util_.SetSeed((0x9E3779B9u * ctr) | 1u);
  } else {
    int randval = rand();
    if (DistributedGlobal())
      Util_.SetSeed(2 * Comm_->MyPID() + randval);
    else {
      int locrandval = randval;
      Comm_->MaxAll(&locrandval, &randval, 1);
      Util_.SetSeed(randval);
    }
  }
  Allocated_ = true;
  UserAllocated_ = true;
  return 0;
}

/* ---- shared-resident vector storage --------------------------------------
 * Epetra_MultiVector payloads allocate from the per-rank arena slice of the
 * shared segment, so any rank can read a peer's vector data in place (the
 * substrate for direct-read halo exchange, and eventually for kernels that
 * read neighbor arrays without any exchange at all). Heap fallback when the
 * arena is off, not yet mapped, or full — the destructor discriminates by
 * address range. */

int Epetra_MultiVector::AllocateForCopy(void) {
  if (Allocated_) return 0;
  if (NumVectors_ <= 0)
    throw ReportError("Number of Vectors = " + toString(NumVectors_) +
                      ", but must be greater than zero", -1);
  Stride_ = Map_.NumMyPoints();
  if (Stride_ > 0) {
    Values_ = (double *)arena_alloc((size_t)Stride_ * NumVectors_ * sizeof(double));
    if (!Values_) Values_ = new double[Stride_ * NumVectors_];
  }
  Pointers_ = new double *[NumVectors_];
  DoubleTemp_ = 0;
  Vectors_ = 0;

  if (ctor_on()) { /* same seed treatment as AllocateForView */
    static unsigned cctr;
    ++cctr;
    if (DistributedGlobal())
      Util_.SetSeed((unsigned)(2 * Comm_->MyPID() + cctr));
    else
      Util_.SetSeed((0x9E3779B9u * cctr) | 1u);
  } else {
    int randval = rand();
    if (DistributedGlobal())
      Util_.SetSeed(2 * Comm_->MyPID() + randval);
    else {
      int locrandval = randval;
      Comm_->MaxAll(&locrandval, &randval, 1);
      Util_.SetSeed(randval);
    }
  }
  Allocated_ = true;
  UserAllocated_ = false;
  return 0;
}

Epetra_MultiVector::~Epetra_MultiVector() {
  if (!Allocated_) return;
  delete[] Pointers_;
  if (!UserAllocated_ && Values_ != 0) {
    if (in_my_arena(Values_)) arena_free((char *)Values_);
    else delete[] Values_;
  }
  if (Vectors_ != 0) {
    for (int i = 0; i < NumVectors_; i++)
      if (Vectors_[i] != 0) delete Vectors_[i];
    delete[] Vectors_;
  }
  if (DoubleTemp_ != 0) delete[] DoubleTemp_;
}

/* LocalMap ctor wrappers: set the flag, chain to the real constructor via
 * RTLD_NEXT (ctors cannot be called by name in C++, but they are plain
 * functions in the Itanium ABI — this is x86-64 Linux only, like the rest
 * of this library). Both the complete-object (C1) and base-object (C2)
 * variants are interposed. */
extern "C" {
typedef void (*lmap_ctor_fn)(void *, int, int, const void *);

void _ZN15Epetra_LocalMapC1EiiRK11Epetra_Comm(void *self, int n, int ib,
                                              const void *comm) {
  static lmap_ctor_fn real =
      (lmap_ctor_fn)dlsym(RTLD_NEXT, "_ZN15Epetra_LocalMapC1EiiRK11Epetra_Comm");
  in_localmap_ctor++;
  real(self, n, ib, comm);
  in_localmap_ctor--;
}

void _ZN15Epetra_LocalMapC2EiiRK11Epetra_Comm(void *self, int n, int ib,
                                              const void *comm) {
  static lmap_ctor_fn real =
      (lmap_ctor_fn)dlsym(RTLD_NEXT, "_ZN15Epetra_LocalMapC2EiiRK11Epetra_Comm");
  in_localmap_ctor++;
  real(self, n, ib, comm);
  in_localmap_ctor--;
}
} /* extern "C" */
