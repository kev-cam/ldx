//
//  ldx_rt_array.cpp — bare-metal ARRAY runtime for nvc-cppgen output.
//
//  The same emitted design that runs on the host runs here on one VexRiscv
//  core: a small delta-cycle event scheduler with NO STL / NO heap (fixed
//  static arrays), and the HAL's fire-and-forget io_emit lowered to a mailbox
//  off-array message (mb_display).  Single core runs the whole sim self-
//  contained; the host bridge formats the (id,value) it receives.
//
//  Build: riscv64-unknown-elf-g++ -march=rv32i -mabi=ilp32 -O2 -nostdlib
//         -ffreestanding -fno-exceptions -fno-rtti -fno-threadsafe-statics
//         -I m1 -T m1/ldx.ld start.S ldx_rt_array.cpp <design>.cpp
//
#include <stdint.h>
#include "ldx_hal.h"

#ifdef __riscv
#include "mailbox.h"
// freestanding: the compiler may emit memset/memcpy for struct/array copies.
// CRITICAL: this core's dpram does NOT honour sub-word (byte) write masks, so
// these MUST use word (32-bit) stores only — a byte store (sb) silently
// corrupts the whole containing word on silicon.  Word loop + read-modify-write
// tail; assumes word-aligned operands (true for struct/array data).
extern "C" void *memset(void *d, int c, unsigned long n)
{
   uint32_t w = (uint32_t)(unsigned char)c * 0x01010101u;
   uint32_t *p = (uint32_t *)d;
   while (n >= 4) { *p++ = w; n -= 4; }
   if (n) { uint32_t m = 0xFFFFFFFFu >> (8u * (4u - (unsigned)n));
            *p = (*p & ~m) | (w & m); }
   return d;
}
extern "C" void *memcpy(void *d, const void *s, unsigned long n)
{
   uint32_t *p = (uint32_t *)d; const uint32_t *q = (const uint32_t *)s;
   while (n >= 4) { *p++ = *q++; n -= 4; }
   if (n) { uint32_t m = 0xFFFFFFFFu >> (8u * (4u - (unsigned)n));
            *p = (*p & ~m) | (*q & m); }
   return d;
}
#else
#include <cstdio>     // host build: validate the same scheduler natively
#endif

// Keep these small: a 16 KB core has little room once code + stack are placed.
// (Sized for the counter; bump per design, watching the stack headroom.)
// which tile runs/reports (broadcast-load puts the worker on every core; only
// this one is active).  Override -DTILE_X / -DTILE_Y to test a specific core.
#ifndef TILE_X
#define TILE_X 0u
#endif
#ifndef TILE_Y
#define TILE_Y 0u
#endif

#define MAXSIG  16
#define MAXPROC 16
#define MAXMAP  16
#define MAXWAIT 8
static const uint32_t NEVER = ~0u;

// NOTE: word-sized flags only.  This VexRiscv core's dpram does not honour
// sub-word (byte) write masks, so `bool`/`uint8_t` field stores silently fail.
// Keep every mutable flag a full 32-bit word.
struct Sig {
   int      width;
   int64_t  value;
   uint32_t event, has_next;
   uint32_t next_time;
   int64_t  next_val;
   int      waiters[MAXWAIT];
   int      nwait;
};
struct Proc {
   ldx_proc_fn fn;
   void       *state;
   uint32_t    wake_time;
   uint32_t    has_trigger;
   Sig        *trig_sig;
   int64_t     trig_val;
};
struct Map { Sig *src, *dst; };

struct ldx_hal { int cur; };

static Sig  g_sig[MAXSIG];   static int g_nsig;
static Proc g_proc[MAXPROC]; static int g_nproc;
static Map  g_map[MAXMAP];   static int g_nmap;
static uint32_t g_now;
static ldx_hal  HAL;

static int  g_run[MAXPROC];  static int g_nrun;
static int  g_inrun[MAXPROC];

// ---- HAL + elaboration API -------------------------------------------------
extern "C" {

void *ldx_var_upref(void *ctx, int64_t hops, int64_t nth)
{ (void)hops; return &((Sig **)ctx)[nth]; }

void *ldx_resolved(ldx_hal_t *hal, void *sig)
{ (void)hal; return &((Sig *)sig)->value; }

void ldx_drive_signal(ldx_hal_t *hal, void *sig, int64_t count)
{
   (void)hal; (void)sig; (void)count;
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0x85, (uint32_t)g_nproc);
      for(volatile int d=0;d<3000;d++){} mb_display(0x86, (uint32_t)(uintptr_t)sig);
      for(volatile int d=0;d<3000;d++){} }
#endif
}

void ldx_sched_waveform(ldx_hal_t *hal, void *sig, int64_t count,
                        int64_t value, int64_t reject, int64_t after)
{
   (void)hal; (void)count; (void)reject;
   Sig *s = (Sig *)sig;
   s->has_next = true; s->next_time = g_now + (uint32_t)after; s->next_val = value;
#if defined(__riscv) && defined(DBG_WF)
   { static int n=0; if (n<6) {
       mb_display(0xA0, (uint32_t)after);       for(volatile int d=0;d<600;d++){}
       mb_display(0xA1, (uint32_t)s->next_time);  for(volatile int d=0;d<600;d++){}
       mb_display(0xA2, (uint32_t)value);       for(volatile int d=0;d<600;d++){}
       n++; } }
#endif
}

void ldx_sched_event(ldx_hal_t *hal, void *sig, int64_t count)
{
   (void)hal; (void)count;
   Sig *s = (Sig *)sig;
   if (s->nwait < MAXWAIT) s->waiters[s->nwait++] = HAL.cur;
}

int64_t ldx_now(ldx_hal_t *hal) { (void)hal; return (int64_t)g_now; }

void ldx_sched_process(ldx_hal_t *hal, int64_t delay)
{
   (void)hal; g_proc[HAL.cur].wake_time = g_now + (uint32_t)delay;
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0x80, (uint32_t)HAL.cur);
      for(volatile int d=0;d<3000;d++){} mb_display(0x81, g_proc[HAL.cur].wake_time);
      for(volatile int d=0;d<3000;d++){} }
#endif
}

int32_t ldx_cmp_trigger(ldx_hal_t *hal, void *sig, int64_t value)
{
   (void)hal;
   Proc &p = g_proc[HAL.cur];
   p.has_trigger = true; p.trig_sig = (Sig *)sig; p.trig_val = value;
   return 1;
}

void ldx_add_trigger(ldx_hal_t *hal, int32_t trig) { (void)hal; (void)trig; }

void ldx_io_emit(ldx_hal_t *hal, uint32_t string_id,
                 const int64_t *args, int32_t nargs)
{
   (void)hal;
   const long long a0 = nargs > 0 ? (long long)args[0] : 0;
#ifdef __riscv
   // Broadcast-load runs this sim on every core; only the egress-reachable tile
   // (0,0) reports, so the host sees one clean sequence.  (No egress FIFO on the
   // single-tile loopback, so spin briefly to let the NIF drain each message.)
   // Multi-value formats ship each arg in order; the host reassembles.
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) {
      for (int32_t k = 0; k < (nargs > 0 ? nargs : 1); k++) {
         mb_display(string_id, (uint32_t)(nargs > 0 ? args[k] : 0));
         for (volatile int d = 0; d < 600; d++) { }
      }
   }
#else
   printf("id=%u: %lld\n", string_id, a0);
#endif
}

void ldx_fail(ldx_hal_t *hal)
{
   (void)hal;
#ifdef __riscv
   MB_CORE_BUSY = 0u;
   for (;;) { }          // assertion failure: halt this core
#else
   exit(1);
#endif
}

// Composite/access heap.  Bump-allocate from a fixed per-core arena (no free;
// a TB process runs to a wait and its transient allocations are abandoned).
void *ldx_alloc(ldx_hal_t *hal, int64_t nbytes)
{
   (void)hal;
   static unsigned char arena[16384];
   static unsigned long top = 0;
   if (nbytes <= 0) nbytes = 8;
   unsigned long n = ((unsigned long)nbytes + 7u) & ~7ul;   // 8-byte align
   if (top + n > sizeof(arena)) top = 0;                    // saturate: reuse
   unsigned char *p = &arena[top];
   top += n;
   for (unsigned long i = 0; i < n; i++) p[i] = 0;          // zero
   return p;
}

void *ldx_scratch(void)
{
   static unsigned char buf[2048];   // zeroed placeholder for unlowered pointers
   return buf;
}

void *ldx_init_signal(ldx_hal_t *hal, int64_t count, int64_t size,
                      int64_t value, int64_t flags)
{
   (void)hal; (void)count; (void)flags;
   Sig *s = &g_sig[g_nsig++];
   s->width = (int)size; s->value = value;
   s->event = s->has_next = false; s->next_time = 0; s->next_val = 0; s->nwait = 0;
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0xC0, (uint32_t)g_nsig);
      for(volatile int d=0;d<3000;d++){} }
#endif
   return s;
}

void ldx_map_signal(ldx_hal_t *hal, void *src, void *dst)
{ (void)hal; g_map[g_nmap].src = (Sig *)src; g_map[g_nmap].dst = (Sig *)dst; g_nmap++; }

void ldx_register_process(ldx_proc_fn fn, void *state, void *ctx)
{
   (void)ctx;
   Proc &p = g_proc[g_nproc++];
   p.fn = fn; p.state = state; p.wake_time = NEVER;
   p.has_trigger = false; p.trig_sig = 0; p.trig_val = 0;
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0xC1, (uint32_t)g_nproc);
      for(volatile int d=0;d<3000;d++){} }
#endif
}

void ldx_elaborate(ldx_hal_t *hal);   // emitted design TU

} // extern "C"

// ---- scheduler -------------------------------------------------------------
static void propagate(void)
{
   bool ch = true;
   while (ch) {
      ch = false;
      for (int i = 0; i < g_nmap; i++) {
         Map &m = g_map[i];
         if (m.dst->value != m.src->value) {
            m.dst->value = m.src->value; m.dst->event = true; ch = true;
         }
      }
   }
}

static void collect(void)
{
   g_nrun = 0;
   for (int i = 0; i < g_nproc; i++) g_inrun[i] = false;
   for (int i = 0; i < g_nproc; i++) {
      if (g_proc[i].wake_time == g_now) {
         if (!g_inrun[i]) { g_inrun[i] = true; g_run[g_nrun++] = i; }
         g_proc[i].wake_time = NEVER;
      }
   }
   for (int s = 0; s < g_nsig; s++) {
      if (!g_sig[s].event) continue;
      for (int w = 0; w < g_sig[s].nwait; w++) {
         int pi = g_sig[s].waiters[w];
         Proc &p = g_proc[pi];
         bool fire = p.has_trigger
            ? (p.trig_sig == &g_sig[s] && g_sig[s].value == p.trig_val) : true;
         if (fire && !g_inrun[pi]) { g_inrun[pi] = true; g_run[g_nrun++] = pi; }
      }
   }
}

static void step(void)
{
   for (int i = 0; i < g_nsig; i++) g_sig[i].event = false;
#if defined(__riscv) && defined(DBG_STEP)
   { static int n=0; if (n<5) {
       mb_display(0x50, (uint32_t)(g_sig[0].has_next?1:0)); for(volatile int d=0;d<600;d++){}
       mb_display(0x51, (uint32_t)g_sig[0].next_time);      for(volatile int d=0;d<600;d++){}
       mb_display(0x52, (uint32_t)g_now);                   for(volatile int d=0;d<600;d++){}
       n++; } }
#endif
   for (int i = 0; i < g_nsig; i++)
      if (g_sig[i].has_next && g_sig[i].next_time == g_now) {
         g_sig[i].has_next = false;
         if (g_sig[i].next_val != g_sig[i].value) {
            g_sig[i].value = g_sig[i].next_val; g_sig[i].event = true;
         }
      }
   propagate();
   collect();
}

static void runset(void)
{
   for (int i = 0; i < g_nrun; i++) {
      int pi = g_run[i];
      HAL.cur = pi;
      g_proc[pi].fn(g_proc[pi].state, &HAL, 1);
   }
}

static void simulate(uint32_t stop)
{
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) {
      uint32_t sp; asm volatile("mv %0, sp" : "=r"(sp));
      mb_display(0x92, (uint32_t)g_nproc); for(volatile int d=0;d<3000;d++){}
      mb_display(0x94, sp);                for(volatile int d=0;d<3000;d++){} }
#endif
   g_now = 0;
   for (int i = 0; i < g_nproc; i++) {
      HAL.cur = i; g_proc[i].fn(g_proc[i].state, &HAL, 0);
#if defined(__riscv) && defined(DBG_BOARD)
      if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0x93, (uint32_t)g_nproc);
         for(volatile int d=0;d<3000;d++){} }
#endif
   }
   propagate();

#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0x62, (uint32_t)g_nproc);
      for(volatile int d=0;d<3000;d++){} }
#endif
   g_nrun = 0;
   for (int i = 0; i < g_nproc; i++) if (!g_proc[i].has_trigger) g_run[g_nrun++] = i;

#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) {
      mb_display(0x60, (uint32_t)g_nrun);              for(volatile int d=0;d<3000;d++){}
      mb_display(0x61, g_proc[0].has_trigger);         for(volatile int d=0;d<3000;d++){} }
#endif
#if defined(__riscv) && defined(DUMP_RESET)
#define DRAIN do { for (volatile int d = 0; d < 600; d++) {} } while (0)
   for (int i = 0; i < g_nproc; i++) { mb_display(0xD0u+i, (uint32_t)(g_proc[i].has_trigger?1:0)); DRAIN; }
   for (int i = 0; i < g_nsig;  i++) { mb_display(0xE0u+i, (uint32_t)g_sig[i].nwait); DRAIN; }
   mb_display(0xF0, (uint32_t)(uintptr_t)g_proc[1].trig_sig); DRAIN;
   for (int i = 0; i < g_nsig; i++) { mb_display(0xF1u+i, (uint32_t)(uintptr_t)&g_sig[i]); DRAIN; }
#endif

   for (;;) {
#if defined(__riscv) && defined(HEARTBEAT)
      { static int hb = 0; if (hb < 30) {
            mb_display(0xB0, g_now); for (volatile int d=0;d<600;d++){}
            mb_display(0xB1, (uint32_t)g_sig[0].value); for (volatile int d=0;d<600;d++){}
            mb_display(0xB2, (uint32_t)g_nrun); for (volatile int d=0;d<600;d++){}
            hb++; } }
#endif
      runset();
      step();
      if (g_nrun > 0) continue;

      uint32_t nt = NEVER;
      for (int i = 0; i < g_nproc; i++) if (g_proc[i].wake_time < nt) nt = g_proc[i].wake_time;
      for (int i = 0; i < g_nsig; i++) if (g_sig[i].has_next && g_sig[i].next_time < nt) nt = g_sig[i].next_time;
#if defined(__riscv) && defined(DBG_BOARD)
      if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { static int n=0; if (n<3) {
         mb_display(0x70, g_proc[0].wake_time); for(volatile int d=0;d<3000;d++){}
         mb_display(0x71, nt);                  for(volatile int d=0;d<3000;d++){} n++; } }
#endif
      if (nt == NEVER || nt > stop) break;
      g_now = nt;
      step();
   }
}

#ifdef __riscv
extern "C" void main(void)
{
   MB_CORE_BUSY = 1u;
   // This is a single-core sim; on a broadcast-loaded array only tile (0,0) runs
   // it (the others idle), so the mesh isn't flooded by 63 copies.
   if (mb_my_x()!=TILE_X || mb_my_y()!=TILE_Y) { MB_CORE_BUSY = 0u; for (;;) {} }
#if defined(__riscv) && defined(DBG_BOARD)
   mb_display(0xAA, 0x1234u); for(volatile int d=0;d<3000;d++){}
#endif
   // start.S does not zero .bss, and broadcast-load only overwrites .text, so a
   // previous worker's BRAM contents may linger.  Reset the allocator counters
   // (every array element is then fully written as it is allocated).
   g_nsig = g_nproc = g_nmap = g_nrun = 0;
   ldx_elaborate(&HAL);
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0xE0, (uint32_t)g_nsig);
      for(volatile int d=0;d<3000;d++){} mb_display(0xE1, (uint32_t)g_nproc);
      for(volatile int d=0;d<3000;d++){} }
#endif
   simulate(50000000u);   // 50 ns, matching the host golden
#if defined(__riscv) && defined(DBG_BOARD)
   if (mb_my_x()==TILE_X && mb_my_y()==TILE_Y) { mb_display(0xEE, 0xDEADu);
      for(volatile int d=0;d<3000;d++){} }
#endif
   MB_CORE_BUSY = 0u;
   for (;;) { }
}
#else
int main(void)
{
   ldx_elaborate(&HAL);
   simulate(50000000u);
   return 0;
}
#endif
