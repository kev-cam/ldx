# LDX runtime editing for AArch64

First step toward "LDX as a JIT" on ARM: patch instructions in a running
process, with the kernel-free, in-process self-modification path. The
running binary writes to its own `.text` after temporarily widening the
page protection to `R+W+X`, then flushes I-cache through GCC's
`__builtin___clear_cache` (emits `DC CVAU` + `IC IVAU` + `ISB` on aarch64).

The companion `python/arm_rewrite.py` does the same kind of patching
offline against an ELF file. This library is the runtime sibling.

## Files

* `ldx_rt.h` / `ldx_rt.c` — `ldx_patch_b()`: replace one 32-bit insn
  with an unconditional `B target`. Reachability: ±128 MB.
* `patch_demo.c` — proves it works. `compute(x) -> x + 1` is patched
  live to redirect to `replacement(x) -> x * 2`. The call goes through
  a `volatile` function pointer so GCC can't CSE the two results.

## Build

```
make
```

Cross-compiles a static aarch64 binary with `aarch64-linux-gnu-gcc`.

## Run on a ZCU104 (or any aarch64 Linux box)

```
$ ./patch_demo a b c
before: compute(4) = 5  (expect 5)
after:  compute(4) = 8  (expect 8)
```

The single `B` insn at `compute`'s entry now lands inside `replacement`,
which `ret`s the doubled value directly to `main`.

## Limits and what's next

* Single 4-byte patch only. Multi-word atomic patching needs a stop-the-
  world step or a trampoline-and-flip trick. Fine for entry-point hijacks.
* `target` must be within ±128 MB of `site`. For larger jumps, emit a
  trampoline (5–6 insns: `adrp`, `add`, `br`) in a scratch page.
* Same-process only. Out-of-process patching needs `ptrace` +
  `process_vm_writev` and a remote `__clear_cache` invocation.
* No locking around concurrent execution. Single-core writes are fine
  because the 4-byte store is atomic, but on SMP another thread mid-
  execution of `compute()` could be inside the function when the entry
  changes. For the offload use case (idle function → offload) this is
  fine; for hot paths we'll need quiescence.
