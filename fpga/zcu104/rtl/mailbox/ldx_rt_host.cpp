//
//  ldx_rt_host.cpp — generic HOST reference runtime for nvc-cppgen output.
//
//  Design-independent: implements the ldx HAL against a small delta-cycle
//  event scheduler and drives whatever ldx_elaborate() (in the emitted TU)
//  builds.  Used to validate emitted C++ against `nvc -r` before cross-
//  compiling to a core.  Link: g++ ldx_rt_host.cpp <design>.cpp -o sim
//
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <set>

#include "ldx_hal.h"

static const uint64_t NEVER = ~0ull;

struct Sig {
   int      width;
   int64_t  value;
   bool     event;
   bool     has_next;
   uint64_t next_time;
   int64_t  next_val;
   std::vector<int> waiters;
};

struct Proc {
   ldx_proc_fn fn;
   void       *state;
   uint64_t    wake_time;
   bool        has_trigger;
   Sig        *trig_sig;
   int64_t     trig_val;
};

struct Map { Sig *src, *dst; };

struct Scheduler {
   std::vector<Sig *>  sigs;
   std::vector<Proc>   procs;
   std::vector<Map>    maps;
   uint64_t            now;
};

struct ldx_hal { Scheduler *sch; int cur; };

static Scheduler S;
static ldx_hal   HAL;

// ---- HAL + elaboration API -------------------------------------------------
extern "C" {

void *ldx_var_upref(void *ctx, int64_t hops, int64_t nth)
{
   (void)hops;
   return &((Sig **)ctx)[nth];
}

// A null signal handle means the handle derived from an unlowered op (signal
// array/record indexing, unwrap).  Treat it as an unknown signal: reads see 0,
// writes/sensitivity are skipped -- never crash on it.
static int64_t g_zero = 0;

void *ldx_resolved(ldx_hal_t *hal, void *sig)
{
   (void)hal;
   if (sig == nullptr) return &g_zero;
   return &((Sig *)sig)->value;
}

void ldx_drive_signal(ldx_hal_t *hal, void *sig, int64_t count)
{
   (void)hal; (void)sig; (void)count;
}

void ldx_sched_waveform(ldx_hal_t *hal, void *sig, int64_t count,
                        int64_t value, int64_t reject, int64_t after)
{
   (void)count; (void)reject;
   if (sig == nullptr) return;
   Sig *s = (Sig *)sig;
   s->has_next  = true;
   s->next_time = hal->sch->now + (uint64_t)after;
   s->next_val  = value;
}

void ldx_sched_event(ldx_hal_t *hal, void *sig, int64_t count)
{
   (void)count;
   if (sig == nullptr) return;
   ((Sig *)sig)->waiters.push_back(hal->cur);
}

void ldx_sched_process(ldx_hal_t *hal, int64_t delay)
{
   hal->sch->procs[hal->cur].wake_time = hal->sch->now + (uint64_t)delay;
}

int32_t ldx_cmp_trigger(ldx_hal_t *hal, void *sig, int64_t value)
{
   if (sig == nullptr) return 0;        // unknown signal: don't arm a dead trigger
   Proc &p = hal->sch->procs[hal->cur];
   p.has_trigger = true;
   p.trig_sig    = (Sig *)sig;
   p.trig_val    = value;
   return 1;
}

void ldx_add_trigger(ldx_hal_t *hal, int32_t trig) { (void)hal; (void)trig; }

// host string table emitted by cppgen into the elab.cpp (host-only)
extern "C" const char *const ldx_strtab[];
extern "C" const char        ldx_strkind[];
extern "C" const unsigned    ldx_strtab_n;

void ldx_io_emit(ldx_hal_t *hal, uint32_t string_id,
                 const int64_t *args, int32_t nargs)
{
   const unsigned long long t = (unsigned long long)(hal->sch->now / 1000000ull);
   printf("@%lluns id=%u: ", t, string_id);
   const int64_t a0 = nargs > 0 ? args[0] : 0;
   if (string_id >= ldx_strtab_n) { printf("%lld\n", (long long)a0); return; }
   const char *s = ldx_strtab[string_id];
   if (ldx_strkind[string_id] == 'L') { fputs(s, stdout); printf("\n"); return; }
   // 'F': literal bytes verbatim; \x01<typecode> renders args[k] per VHDL 'image
   int k = 0;
   for (const char *p = s; *p; p++) {
      if (*p == '\x01' && p[1]) {
         const int64_t v = k < nargs ? args[k++] : 0;
         switch (p[1]) {
         case 'C': printf("'%c'", (int)(v & 0xff)); break;            // character'image
         case 'B': fputs(v ? "true" : "false", stdout); break;        // boolean'image
         case 'T': printf("%lld fs", (long long)v); break;            // time'image
         default:  printf("%lld", (long long)v); break;               // 'I' integer'image
         }
         p++;
      }
      else putchar(*p);
   }
   printf("\n");
}

void ldx_fail(ldx_hal_t *hal)
{
   (void)hal;
   fflush(stdout);
   exit(1);        // matches nvc -r aborting on an ERROR/FAILURE assertion
}

void *ldx_alloc(ldx_hal_t *hal, int64_t nbytes)
{
   (void)hal;
   // Allocation sizes can be UNDER-computed when a length op is stubbed (e.g. a
   // concat whose dynamic piece length is unknown), so a later COPY/STORE would
   // overflow.  Over-allocate generously and zero it -- these are transient.
   if (nbytes < 256) nbytes = 256;
   void *p = calloc(1, (size_t)nbytes + 256);
   return p;
}

void *ldx_scratch(void)
{
   static char buf[1 << 16];   // 64 KiB, zero-initialised; never written meaningfully
   return buf;
}

void *ldx_init_signal(ldx_hal_t *hal, int64_t count, int64_t size,
                      int64_t value, int64_t flags)
{
   (void)hal; (void)count; (void)flags;
   Sig *s = new Sig();
   s->width = (int)size;
   s->value = value;
   s->event = s->has_next = false;
   s->next_time = 0; s->next_val = 0;
   S.sigs.push_back(s);
   return s;
}

void ldx_map_signal(ldx_hal_t *hal, void *src, void *dst)
{
   (void)hal;
   S.maps.push_back({ (Sig *)src, (Sig *)dst });
}

void ldx_register_process(ldx_proc_fn fn, void *state, void *ctx)
{
   (void)ctx;
   Proc p{};
   p.fn = fn; p.state = state; p.wake_time = NEVER;
   p.has_trigger = false; p.trig_sig = nullptr; p.trig_val = 0;
   S.procs.push_back(p);
}

// supplied by the emitted design translation unit
void ldx_elaborate(ldx_hal_t *hal);

} // extern "C"

// ---- scheduler -------------------------------------------------------------
static void propagate(void)
{
   bool changed = true;
   while (changed) {
      changed = false;
      for (auto &m : S.maps) {
         if (m.dst->value != m.src->value) {
            m.dst->value = m.src->value;
            m.dst->event = true;
            changed = true;
         }
      }
   }
}

static std::vector<int> step(void)
{
   for (auto *s : S.sigs) s->event = false;
   for (auto *s : S.sigs) {
      if (s->has_next && s->next_time == S.now) {
         s->has_next = false;
         if (s->next_val != s->value) { s->value = s->next_val; s->event = true; }
      }
   }
   propagate();

   std::set<int> woken;
   for (size_t i = 0; i < S.procs.size(); i++)
      if (S.procs[i].wake_time == S.now) { woken.insert(i); S.procs[i].wake_time = NEVER; }
   for (auto *s : S.sigs) {
      if (!s->event) continue;
      for (int w : s->waiters) {
         Proc &p = S.procs[w];
         if (p.has_trigger) {
            if (p.trig_sig == s && s->value == p.trig_val) woken.insert(w);
         }
         else woken.insert(w);
      }
   }
   return std::vector<int>(woken.begin(), woken.end());
}

static void simulate(uint64_t stop)
{
   HAL.sch = &S;
   S.now = 0;

   for (size_t i = 0; i < S.procs.size(); i++) {       // reset
      HAL.cur = i;
      S.procs[i].fn(S.procs[i].state, &HAL, 0);
   }
   propagate();                                        // settle port maps

   std::vector<int> torun;                             // initial run
   for (size_t i = 0; i < S.procs.size(); i++)
      if (!S.procs[i].has_trigger) torun.push_back(i);

   for (;;) {
      for (int i : torun) { HAL.cur = i; S.procs[i].fn(S.procs[i].state, &HAL, 1); }
      torun = step();
      if (!torun.empty()) continue;

      uint64_t nt = NEVER;
      for (auto &p : S.procs) if (p.wake_time < nt) nt = p.wake_time;
      for (auto *s : S.sigs) if (s->has_next && s->next_time < nt) nt = s->next_time;
      if (nt == NEVER || nt > stop) break;
      S.now = nt;
      torun = step();
   }
}

int main(int argc, char **argv)
{
   uint64_t stop_ns = (argc > 1) ? strtoull(argv[1], nullptr, 10) : 50;
   HAL.sch = &S;
   ldx_elaborate(&HAL);
   simulate(stop_ns * 1000000ull);
   return 0;
}
