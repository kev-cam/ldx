# ldx/mpi — MPI call interposition and SMP comm microbenchmarks

**STATUS: PARKED (2026-07-05), tools kept for reuse.** The campaign took
ladder-class decks from stock MPI to −28% wall at np16 (collectives → shm
snoop protocol, halo → SPSC rings, 117k constructor-collectives eliminated,
single-pass ICGS), proved communication is exhausted as a category on this
box (in-MPI <2% of wall), and pivoted to behavioral-model-assisted solving.
Portable beyond Xyce: `mpi_count.c` (PMPI census + call-site attribution)
and `memprof.c` (allocation census) work on ANY MPI/C++ application
unchanged; `shmcomm.cpp`'s PMPI collective interposers, ring/arena
machinery, and the AZ_manage_memory rollover generalize to any Epetra/
AztecOO user; the vtable-replacement-via-LD_PRELOAD pattern generalizes to
any shared-library C++ seam. Known limit: ShmDistributor delegates (safely,
via plan fingerprint) when plans are built through the non-virtual
CreateFromSendsAndRecvs path.

Link-hacking tools from the Xyce shm-comm project: measure what an MPI
application actually does on the wire, attributed to the shared object that
made each call, so you know which traffic flows through replaceable C++
vtable seams and which bypasses them.

## libmpicount.so — PMPI profiling shim with caller attribution

LD_PRELOAD shim wrapping ~30 MPI entry points via the standard PMPI profiling
interface. For every call it records count, payload bytes, and wall time, and
resolves the caller's return address to its shared object (`dladdr`, cached).
Per-rank report at `MPI_Finalize`; rank 0 also mirrors to stderr.

```bash
make                              # needs mpicc
mpirun -np 4 -x LD_PRELOAD=$PWD/libmpicount.so ./app args...
# reports: /tmp/mpicount.rank<N>.txt   (override prefix with -x MPICOUNT_PREFIX=...)
```

Assumes MPI_THREAD_SINGLE (counters unlocked). Overhead ~40ns/call plus a
one-time dladdr per unique call site.

Relation to core ldx: this uses the MPI profiling convention (strong
`MPI_*` over weak `PMPI_*`) instead of GOT patching; the GOT walker in
`src/ldx.c` could subsume it later with per-call-site (not per-module)
attribution for free.

## bench/ — SMP transport ground truth

- `c2c_pingpong` — single-cache-line handoff latency between two pinned
  cores (one MESI transfer per turn).
- `shm_allreduce` — flat allreduce over a central atomic counter barrier.
  Kept as a cautionary tale: the shared counter serializes line bounces and
  LOSES to OpenMPI at 8 ranks.
- `shm_allreduce2` — contention-free allreduce: each rank publishes
  value+generation in its own cache line, leader polls N independent lines
  (loads pipeline), publishes one result line all ranks snoop. Beats
  MPI_Allreduce ~6x at 8 ranks and stays flat in N.
- `mpi_allreduce_bench` — the MPI_Allreduce(1 double) baseline to beat.

Measured 2026-07 on clevo-lx (i7-10875H, one shared L3, loaded box):
handoff 24.5ns SMT / ~70ns cross-core; MPI_Allreduce 549/911/1266 ns at
np=2/4/8; shm_allreduce2 ~170-230 ns flat.

## libshmcomm.so — shared-memory collectives via linker vtable replacement

The payoff of the profiling: `shmcomm.cpp` DEFINES
`Epetra_MpiComm::Barrier/SumAll/MaxAll/MinAll/Broadcast` with the exact
mangled symbols libepetra.so was linked against, so under LD_PRELOAD the
loader binds libepetra's vtable slots (and PLT calls) to our implementations
— vtable replacement done by ld.so, no source changes anywhere. It also
interposes the C `MPI_Barrier`/`MPI_Allreduce`/`MPI_Bcast` symbols to catch
Epetra_MpiDistributor's direct barriers and Xyce's free-function collectives.

All captured collectives run on the contention-free generation protocol from
`bench/shm_allreduce2` over one small `/dev/shm` segment (per-rank slot lines
+ one snooped result line). Guarded fallback to PMPI for: non-MPI_COMM_WORLD
comms, payloads > 4KB, np>64, multi-node runs, np==1, or `XYCE_SHMCOMM=0`.
MPI stays initialized underneath as transport of last resort. Large-payload
reductions stay on MPI deliberately: they are bandwidth-bound, where MPI is
fine — the shm win is small-op latency.

v1.1 hardening (all guards are rank-uniform for a conformant app, but
library error paths can fork the collective stream per rank — seen live in
Ifpack_Amesos.cpp:230 error handling, which issues different world
collectives on failing vs healthy ranks): the writer cross-checks op+count
in every slot; readers verify the result line matches their op (no silent
cross-op consumption); spins abort after `XYCE_SHMCOMM_SPIN_TIMEOUT_S`
(default 300, 0=never) instead of hanging; every rank keeps a 32-entry op
tape dumped on any FATAL and on SIGTERM (so sibling ranks report their side
when one aborts); `XYCE_SHMCOMM_TRACE_FROM=<gen>` logs routing decisions.

```bash
make shmcomm TRILINOS_INC=$HOME/trilinos-mpi/include   # must match target's libepetra
mpirun -np 8 -x LD_PRELOAD=$PWD/libshmcomm.so [-x XYCE_SHMCOMM_STATS=1] Xyce deck.cir
```

Measured on Xyce (2000-node ladder, Belos, WSL/5955WX, July 2026):
- np=8: in-MPI time 30.3% -> 3.2% of wall; 129k Allreduce + 28k Barrier
  fully absorbed by shm; wall -11% (medians 1608 -> 1425 ms incl. mpirun
  startup). np=16: -11%. np=4: within noise (MPI shm collectives are
  already cheap at 4 ranks).
- Output bitwise identical to the MPI baseline at np=4 and np=8.

v2 adds the **SPSC-ring halo distributor**: interposing
`Epetra_MpiComm::CreateDistributor()` returns a `ShmDistributor
: public Epetra_MpiDistributor` whose fixed-size Do/DoReverse move bytes
through one SPSC ring per ordered rank pair (`XYCE_SHMCOMM_RING_KB`,
default 256, rounded to a power of two) — no MPI_Barrier (the ready-send
handshake is structurally unnecessary), no tag matching, no posted
receives, no framing (both ends know every exchange's byte count from the
plan; pairwise FIFO = MPI's non-overtaking guarantee). The parent still
builds the plan, so variable-size and non-grouped cases delegate to real
MPI with full state; transport choice is made rank-uniform by a
PMPI_Allreduce agreement at plan-creation time. A chunked progress loop
(always draining inbound while pushing outbound) makes ring-full cycles
deadlock-free. `XYCE_SHMCOMM_HALO`: 0=MPI, 1=forward rings, 2=both
(default).

Hard-won dispatch lesson: the parent's variable-size `Do` calls `DoPosts`
and `DoWaits` VIRTUALLY, so a subclass whose `DoWaits` returns early hands
the caller un-waited Irecv buffers (Epetra_CrsGraph asserts
`intptr[0]==ToRow`). Delegated-posts must be the default assumption, and
the variable-size posts overrides exist purely to maintain that flag.

v3 climbs above the transport entirely: a call-site census
(`MPICOUNT_SITES=1`, 3-frame chains) showed **94% of all reductions were
object-lifecycle ceremony** — every Belos workspace view/LocalMap
construction fires collectives whose answers are run-constants
(AllocateForView MaxAll's a rand() seed; LocalMap::CheckInput validates
sizes; IsDistributedGlobal re-answers a constant). v3 eliminates them at
the semantic level: counter-derived uniform seeds, skipped debug
validation, and a LocalMap-ctor flag (dlsym-chained C1/C2 constructor
wrappers) that makes IsDistributedGlobal locally decidable exactly where
the class contract guarantees numGlobal==numMy on every rank. Genuine
BlockMaps keep the true MinAll. `XYCE_SHMCOMM_CTOR=0` restores stock.
Global sync points per timestep: ~1,300 -> ~114.

Ladder+Belos wall times (same-day medians, 3 trials, incl. mpirun start):
np4 1658->1553ms (-6%), np8 1362->1233ms (-9.5%), np16 1757->1384ms
(-21%). The gain GROWS with rank count — each eliminated sync point was a
skew-absorption event, a cost invisible to inside-call accounting. Stock
degrades +29% from np8->np16; shm +12%: the scaling wall moved. Output
bitwise-identical at np4/np8 throughout.

v4 adds **shared-resident vectors**: Epetra_MultiVector payloads allocate
from a per-rank arena inside the segment (interposed AllocateForCopy +
destructor, size-class free-list, transparent heap fallback;
`XYCE_SHMCOMM_ARENA_MB`, default 64/rank), so any rank can read a peer's
vector data in place. On top of it, `XYCE_SHMCOMM_HALO=3` exchanges halos
by direct read: sender publishes {epoch, offset, bytes}, receiver copies
straight from the sender's arena slice and acks — one SPSC line each way,
no FIFO bookkeeping. Bitwise-identical at np4/np8; measured a WASH vs the
rings (ladder np4/8/16 and breaker all within noise): with pack/unpack
inherent to the plan, copy-based exchange was already at its floor — the
remaining halo cost is two unavoidable copies plus arrival skew (<1% of
wall on the ladder, ~2% on the breaker). The residency substrate is the
real deliverable: kernel-level neighbor reads (matvec against a peer's
slice, no exchange at all) are the next altitude, and that is linear-
algebra-backend work, not interposition. Rings (HALO=2) stay the default.

Belos dot batching (uncommitted, Trilinos + Xyce trees): the Krylov loop
costs 3 reductions/iteration (two ICGS projection passes + one norm).
BelosBlockGmresSolMgr.hpp now forwards "Orthogonalization Passes" ->
maxNumOrthogPasses (plus a fix for its latent null-RCP deref in the DGKS
branch), and Xyce's BelosSolver reads XYCE_ORTHO_PASSES. Single-pass ICGS
(Belos's own "fast" preset) trades +2.1% iterations for -22% sync points:
np8 -6.4%, np16 -7.6% wall on the ladder. NOTE: Xyce compiles against the
INSTALLED Trilinos headers — the patched BelosBlockGmresSolMgr.hpp must be
copied to ~/trilinos-mpi/include (done; a Trilinos reinstall overwrites it).

Companion Xyce source patch (uncommitted, branch smp-load-prototype):
DampedNewton::converged_ fuses its two allgather-based max norms (4
collectives) into one maxAll(double[2]) on the non-verbose path, and
innerDevicesConverged memoizes "no ExternDevices globally" instead of an
MPI_Allreduce(LAND) on an empty list every Newton iteration. Bitwise-
identical vs its own tree; wall-neutral on the ladder (~400 convergence
checks/run — the sync budget there is now real Belos dots). Baseline
forensics lesson: always rebuild the unpatched tree as the comparison
binary — a stale reference binary from before unrelated branch commits
produced a phantom 5.8e-13 "regression" that cost half a day.

Ladder np8 measurements (v2, bitwise-identical output at np4/np8):
distributor pt2pt Rsend 15,405 -> 220, Irecv 16,863 -> 1,709, Waitall
16,735 -> 1,414; fixed-size barriers eliminated (27,749 -> 6,972 at np4);
in-MPI 30.3% (stock) -> 3.2% (v1) -> 1.6% (v2) of wall; shm run-to-run
variance collapsed (1264/1265/1265 ms). Remaining residual: variable-size
setup transfers, Zoltan partitioning, Xyce setup gathers.

## Headline result from profiling Xyce (2000-node ladder, np=4, 126 steps)

| solver  | MPI calls | in-MPI | hot-path traffic through Epetra_Comm seam |
|---------|-----------|--------|-------------------------------------------|
| Belos   | 285k      | 11.5%  | ~99% (124k Allreduce, 97% from libepetra) |
| AztecOO | 1138k     | 17.9%  | ~13% — 973k raw Send/Irecv/Wait from libaztecoo (hand-rolled trees + halo) |

So an Epetra_Comm vtable replacement covers Belos runs almost completely;
AztecOO must be avoided (or GOT-patched — an ldx job). Bonus find: Epetra's
ready-send protocol issues an MPI_Barrier per halo exchange (~220/step);
SPSC shm rings make that whole dance unnecessary.
