# Verilator/iverilog throughput benchmarks

Tiny RTL workloads to compare simulation speed across:

* **x86** (Verilator and iverilog)
* **A53** (Verilator and iverilog) on a ZCU104 PetaLinux
* **5×5 mesh** (custom RV32I + SHA-CFU) — for SHA-256 only, since the mesh
  doesn't yet run Verilator/iverilog output natively

## Workloads

* `crc32/` — 32-bit IEEE 802.3 CRC, one byte per cycle. Tightly inlined by
  Verilator → no `vl_*` helper calls at all.
* `sha256/` — single-block SHA-256, one round per cycle. 64 round cycles +
  load/finalize per hash. Tightly inlined by Verilator too.

## Numbers (SHA-256, "abc" digest verified at every measurement)

| platform                | rate         | vs x86 Verilator |
| ----------------------- | ------------ | ---------------- |
| x86 Verilator sim       | 143.92 kH/s  | 1.00×            |
| 5×5 mesh (custom RV32I) | 58.30 kH/s   | 0.41×            |
| A53 Verilator sim       | 27.35 kH/s   | 0.19×            |
| x86 iverilog            | 0.363 kH/s   | 0.0025×          |
| A53 iverilog            | 0.071 kH/s   | 0.0005×          |

Verilator is ~400× faster than iverilog on both x86 and A53 because Verilator
compiles the design to C++ and lets the host C++ compiler inline everything;
iverilog dispatches each event through vvp's bytecode interpreter.

## Why iverilog is the LDX-acceleration target

iverilog's vvp interpreter dispatches into a stable set of 4-state vector
ops (`v4_and`, `v4_or`, `v4_xor`, `v4_not`, …) which are precisely what
[`test/c2v_ivl.c`](../../test/c2v_ivl.c) extracted years ago and what
[`simulators/verilator/cfu_vl_*.v`](../../simulators/verilator/) holds as
gate sets. The LDX flow is therefore:

1. Build vvp on the target (we have that on A53 now: native build of
   `/usr/local/src/iverilog` per `/usr/local/src/iverilog/INSTALL.txt`).
2. At load time, LDX patches `libvvp.so`'s 4-state op call sites to
   `CUSTOM_0` instructions backed by the per-core CFU gates.
3. Each CUSTOM_0 is single-cycle on the FPGA where the original takes
   ~10-30 RV32I cycles, so the per-event interpreter cost drops.
4. Parallelism: run N independent vvp instances on N mesh cores.

Verilator is the wrong target for runtime acceleration because there are no
function-call sites to intercept — every primitive is already inlined.

## Repro

x86 (any host with `verilator` 5+ and `iverilog` 13+):

```sh
cd sha256
verilator --cc Sha256.v --exe sim_main.cpp -CFLAGS "-O2" --build
./obj_dir/VSha256 1000000

iverilog -g2012 -o bench.vvp Sha256.v tb_bench.v
time vvp bench.vvp +ITERS=1000
```

A53 (PetaLinux on ZCU104):

```sh
# Native build of /usr/local/src/iverilog on A53 already done; vvp lives
# at /usr/local/bin/vvp and finds libvvp.so via /etc/ld.so.conf.d/local.conf.
scp -r sha256 root@zcu104:/tmp/
ssh root@zcu104 'cd /tmp/sha256 && verilator --cc Sha256.v --exe sim_main.cpp -CFLAGS "-O2" --build && ./obj_dir/VSha256 1000000'
ssh root@zcu104 'cd /tmp/sha256 && iverilog -g2012 -o bench.vvp Sha256.v tb_bench.v && time vvp bench.vvp +ITERS=1000'
```

Mesh (5×5 ldx_mesh on ZCU104) — see `fpga/zcu104/sw/sha_pipe_host.c`.
