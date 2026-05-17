// vsim_main.cpp — Phase 2: live-patch Verilator's nba_sequent so the
// counter's per-cycle increment is computed on the FPGA mesh.
//
// Sequence:
//   1. mesh_init() loads worker.bin into all 25 RV32I cores, releases reset.
//   2. Run a few cycles with stock Verilator code — cnt goes 1,2,3,...
//   3. ldx_patch_function() redirects nba_sequent → my_sequent_mesh.
//   4. Run more cycles. my_sequent_mesh calls mesh_call(2,3,FN_INC,1,&cnt);
//      the (2,3) softcore returns cnt+1, which we write back to vlSelf->cnt.
//      Externally, the counter keeps incrementing — but each tick is now
//      computed by a softcore in the PL fabric.

#include "VCounter.h"
#include "VCounter___024root.h"
#include "../ldx_rt.h"
#include "mesh_host.h"
#include <stdio.h>
#include <unistd.h>

#define FN_INC 3

extern void VCounter___024root___nba_sequent__TOP__0(VCounter___024root *vlSelf);

extern "C" void my_sequent_mesh(VCounter___024root *vlSelf) {
    if (vlSelf->rst) { vlSelf->cnt = 0; return; }
    uint32_t arg = vlSelf->cnt;
    uint32_t r = mesh_call(2, 3, FN_INC, 1, &arg);
    vlSelf->cnt = static_cast<uint8_t>(r);
}

// Trampoline: Verilator's eval_phase__nba reads x0 after calling eval_nba
// (which originally tail-calls a x0-preserving leaf). Our replacement
// clobbers x0, so we wrap it: save x0, call replacement, restore x0.
extern "C" __attribute__((naked)) void my_sequent_trampoline(void) {
    asm volatile (
        "stp x29, x30, [sp, #-32]!\n\t"
        "mov x29, sp\n\t"
        "str x0, [sp, #16]\n\t"
        "bl  my_sequent_mesh\n\t"
        "ldr x0, [sp, #16]\n\t"
        "ldp x29, x30, [sp], #32\n\t"
        "ret"
    );
}

static void tick(VCounter &top) {
    top.clk = 0; top.eval();
    top.clk = 1; top.eval();
}

int main(int argc, char **) {
    (void)argc;
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    VCounter top;
    top.rst = 1;
    for (int i = 0; i < 4; i++) tick(top);
    top.rst = 0;

    printf("=== before patch: Verilator computes (cnt += 1) ===\n");
    for (int i = 0; i < 5; i++) {
        tick(top);
        printf("cycle %d: cnt = %u\n", i, top.cnt);
    }

    printf("[host] calling mesh_init...\n");
    if (mesh_init("worker.bin") != 0) {
        fprintf(stderr, "mesh_init failed\n"); return 1;
    }
    printf("[host] mesh_init OK\n");

    int rc = ldx_patch_function(
        reinterpret_cast<void *>(&VCounter___024root___nba_sequent__TOP__0),
        reinterpret_cast<void *>(&my_sequent_trampoline));
    printf("ldx_patch_function rc = %d\n", rc);
    if (rc != 0) return 1;

    printf("=== after patch: mesh (2,3) computes cnt += 1 ===\n");
    for (int i = 5; i < 12; i++) {
        tick(top);
        printf("cycle %d: cnt = %u\n", i, top.cnt);
    }

    mesh_shutdown();
    return 0;
}
