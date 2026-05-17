# Verilator output → live-patched → mesh offload

End-to-end demo of LDX runtime editing on top of a Verilator-generated
simulator: a Verilog counter whose per-cycle increment is, after a live
patch, computed by a softcore in the 5×5 ldx mesh on the ZCU104's PL.

## Flow

1. `mesh_init()` mmaps the bridge at PS physical `0xA0000000`, holds all
   25 softcores in reset, blits `worker.bin` into each core's BRAM,
   releases reset.
2. `Verilator` simulates `Counter.v` natively on the A53 for a few
   cycles — increments come from `VCounter___024root___nba_sequent__TOP__0`,
   which Verilator generates as a small leaf function. `cnt` goes 1,2,3,4,5.
3. `ldx_patch_function()` overwrites that function's first instruction
   with `B my_sequent_trampoline`.
4. The trampoline saves `x0`, calls `my_sequent_mesh`, restores `x0`, rets.
5. `my_sequent_mesh` does `mesh_call(2, 3, FN_INC, 1, &cnt)`: pushes a
   header+arg into the west boundary FIFO at row 3, waits on the same
   endpoint for the OP_RETURN. Softcore (2,3) runs `worker.c`'s dispatch,
   returns `cnt+1`. Result is written back into `vlSelf->cnt`.
6. From the eval chain's perspective, `nba_sequent` returned; Verilator
   continues. `cnt` keeps incrementing 6,7,8,9,10,11,12 — but each tick
   was computed in the PL fabric.

## Run

On a ZCU104 with the mesh bitstream loaded:

```
$ scp -r ../arm-runtime root@zcu104:/tmp/
$ scp fpga/zcu104/sw/worker.bin root@zcu104:/tmp/arm-runtime/verilator-patch/
$ ssh root@zcu104
# cd /tmp/arm-runtime/verilator-patch
# make && ./obj_dir/VCounter
```

Expected output:

```
=== before patch: Verilator computes (cnt += 1) ===
cycle 0: cnt = 1
... cycle 4: cnt = 5
=== after patch: mesh (2,3) computes cnt += 1 ===
cycle 5: cnt = 6
... cycle 11: cnt = 12
```

## The x0 gotcha

Verilator's generated code relies on `eval_nba` (and the leaf
`nba_sequent` it tail-calls) being x0-preserving. The caller does
`bl eval_nba; add x0, x0, #0x30; bl clear`, treating `x0` as if it
were live across the call. Per AAPCS, `x0` is caller-saved; the original
leaf just never wrote it, so the optimizer treated it as preserved.

A C/C++ replacement that calls `fprintf` (or anything else that takes
multiple args) will clobber `x0`, and the next instruction in
`eval_phase__nba` will dereference garbage and segfault. The
`__attribute__((naked))` trampoline saves/restores `x0` around the
real handler:

```c
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
```

A more general solution (for arbitrary Verilator functions) is to
discover the caller's calling-convention assumptions from the generated
code and wrap accordingly. For now this hand-written shim is enough.

## Performance

Each per-cycle increment is ~one AXI4-Lite write (push hdr), one push
(arg), some softcore hops, one read (return hdr), one read (return
arg). At pl_clk0 = 100 MHz that's roughly 1–2 µs/cycle of simulated
time — way slower than letting the A53 run the original `cnt = cnt+1`
(under 10 ns). The point isn't speed; the point is the wire-up works
and we can swap mesh-side responder firmware to do anything `worker.c`
expects.

## Next

* Replace `FN_INC` with a c2v-emitted gate set for a heavier function
  where the FPGA actually wins.
* Have LDX automatically pick the patch target by reading the
  Verilator-generated symbol table.
* Support multi-word atomic patches via trampoline-and-flip when a B
  reach isn't enough.
