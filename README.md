# ldx — Programmable Linker Extensions

Dynamic code replumbing via Linux linker instrumentation. Replace, intercept, profile, and distribute function calls at runtime — without recompilation or source access.

## What It Does

ldx intercepts the dynamic linker's symbol resolution (GOT/PLT patching) to:

1. **Replace** any dynamically-linked function at runtime (`dlreplace`)
2. **Profile** functions with zero-overhead entry/exit hooks and timing
3. **Pipe** function calls through an abstraction layer (`Pipe<Args, Ret>`)
4. **Serialize** call arguments for network transport (Pass-by-Value conversion)
5. **Forward** syscalls over TCP to a remote machine
6. **Container** applications in isolated namespaces with piped OS access
7. **Shard** applications across multiple machines, FPGAs, or SpiNNaker boards
8. **Rewrite** compiled binaries to use custom hardware instructions (x86, ARM, RISC-V)
9. **Convert** C functions to synthesizable Verilog for FPGA acceleration

## Quick Start

```bash
make                  # build everything
make test             # run all tests
make gen              # generate syscall wrappers
```

### Profile an unmodified binary

```bash
# CLI wrapper
./ldx -p sin,cos,strlen -- ./mybinary

# Or with env vars
LDX_PROFILE=sin,cos LD_PRELOAD=./libldx.so ./mybinary

# From a config file
./ldx -c profile.json -- ./mybinary

# List patchable symbols
./ldx --list-got ./mybinary
```

### Run in a container

```bash
# Isolated namespaces (PID, mount, UTS, IPC) — no root needed
./ldx --container -- /usr/bin/hostname
# → "ldx-container"

./ldx --container -- /usr/bin/id
# → "uid=0 gid=0"
```

### Remote syscall execution

```bash
# On the host (where OS resources live):
./ldx-server --port 9801

# On a remote machine (where compute runs):
LDX_SERVER_HOST=host-ip LDX_SERVER_PORT=9801 \
  LD_PRELOAD=./libldx_sock.so ./myapp
# All file I/O, stat, etc. execute on the host machine
```

### Container migration

```bash
# Check container status
python3 python/ldx_ctl.py container:9800 status

# Disconnect before moving
python3 python/ldx_ctl.py container:9800 disconnect

# After moving, reconnect to new server
python3 python/ldx_ctl.py container:9800 reconnect newhost:9801
```

### Rewrite binaries for custom hardware

Replace function calls with custom instructions — no compiler modifications needed.
Compile with stock GCC, rewrite afterward.

```bash
# RISC-V: replace sin/cos with CUSTOM_0 instructions (zero overhead)
python3 python/riscv_rewrite.py -i app.elf -o app.hw -m mapping.json

# AArch64: replace with UDF traps (route to FPGA via kernel handler)
python3 python/arm_rewrite.py -i app.elf -o app.hw --func sin:udf:0x0000

# x86_64: replace with UD2 traps (SIGILL handler dispatches to FPGA)
python3 python/x86_rewrite.py -i app -o app.hw --func sin:0x00:0x00

# x86_64: run patched binary live with trap handler
LD_PRELOAD=./trap_handler.so ./app.hw

# Scan any binary for rewritable call sites
python3 python/riscv_rewrite.py -i app --scan
```

### Convert C functions to Verilog (FPGA acceleration)

```bash
# List convertible functions
python3 python/c2v.py mycode.c -f add --list

# Convert a function to synthesizable Verilog
python3 python/c2v.py mycode.c -f popcount -o popcount.v

# Validate: C → Verilog → Verilator → compare against original
python3 python/c2v_test.py mycode.c -f popcount

# Generate FPGA build directory (Quartus project + build script)
python3 python/c2v.py mycode.c -f add --fpga

# Full FPGA pipeline (tested on DE2i-150: Atom + Cyclone IV GX):
#   1. Profile       → find hot function
#   2. c2v           → generate Verilog
#   3. Verilator     → validate correctness
#   4. c2v --fpga    → generate Quartus project
#   5. Quartus       → synthesize to FPGA
#   6. JTAG program  → load bitstream
#   7. Atom calls function over PCIe BAR0
```

Supported C constructs: arithmetic, bitwise, shifts, ternary (→ MUX),
compound assignment chains, struct returns (→ multiple output ports),
bounded for-loop unrolling, local arrays, type casts, variable reassignment.
27 functions validated, 203 Verilator test vectors, 0 failures.

### FPGA acceleration (DE2i-150)

```bash
# The Atom CPU calls C functions that execute on the Cyclone IV GX FPGA
# over PCIe x1. The c2v converter generates combinational Verilog,
# Quartus synthesizes it, and the result is memory-mapped to PCIe BAR0.

# Build and program
cd fpga/quartus
quartus_sh --flow compile ldx_accel
quartus_pgm -c "USB-Blaster" -m JTAG -o "P;ldx_accel.sof"

# Test from Atom (write args to BAR0, read result)
python3 -c "
import mmap, os, struct
fd = os.open('/sys/bus/pci/devices/0000:01:00.0/resource0', os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 8192, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
m[0x00:0x04] = struct.pack('<I', 42)   # arg0
m[0x04:0x08] = struct.pack('<I', 58)   # arg1
result = struct.unpack('<I', m[0x40:0x44])[0]
print(f'add(42, 58) = {result}')       # → 100 (computed in FPGA)
"
```

### Orchestrate sharded applications

```bash
# Start the controller
python3 python/ldx_controller.py --port 9900

# Register hardware
curl -X POST localhost:9900/nodes \
  -d '{"name":"server1","host":"192.168.1.10","cores":8,"arch":"x86_64"}'

# Create and place shards
curl -X POST localhost:9900/shards -d '{"name":"query-engine"}'
curl -X POST localhost:9900/shards/0/place -d '{"node_id":0}'

# Register functions and routes
curl -X POST localhost:9900/functions \
  -d '{"name":"process_query","owner_shard_id":0}'
curl -X POST localhost:9900/routes \
  -d '{"from_shard":0,"to_shard":1,"type":"function"}'

# Migrate a shard to different hardware
curl -X POST localhost:9900/shards/0/migrate -d '{"node_id":1}'
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ldx-controller :9900                      │
│              (topology, placement, migration)                │
└──────────────────────────┬──────────────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   ┌─────────┐       ┌─────────┐       ┌─────────┐
   │ Shard A │──pipe──│ Shard B │──pipe──│ Shard C │  function calls
   │ (x86)   │       │ (FPGA)  │       │ (ARM)   │  between shards
   └────┬────┘       └────┬────┘       └────┬────┘
        │                 │                 │
   ┌────▼────┐       ┌────▼────┐       ┌────▼────┐
   │ OS Pipe │       │ OS Pipe │       │ OS Pipe │  syscalls to host
   │ Server  │       │ Server  │       │ Server  │
   └─────────┘       └─────────┘       └─────────┘
```

### Core Layers

| Layer | Files | Purpose |
|-------|-------|---------|
| GOT/PLT patching | `src/ldx.c` | Walk ELF relocations, patch GOT entries via `mprotect` |
| Hooks & profiler | `src/ldx.c` | x86_64 trampoline generation, entry/exit timing |
| PbV serialization | `src/ldx_pbv.c` | Serialize pointer args into flat packets |
| Pipe abstraction | `src/ldx_pipe.h` | `Pipe<Args,Ret>` with virtual `write`/`propagate` |
| Socket pipe | `src/ldx_socket_pipe.h` | `SocketPipe` — forward calls over TCP |
| Syscall wrappers | `gen/ldx_syscall_pbv.*` | 53 syscalls with Args structs + Pipe typedefs |
| Container | `src/ldx_container.c` | Namespace isolation (user, PID, mount, UTS, IPC, net) |
| Control socket | `src/ldx_control.c` | JSON protocol for disconnect/reconnect/suspend |
| Registry | `src/ldx_registry.c` | Track nodes, shards, functions, routes |
| Controller | `python/ldx_controller.py` | REST API for topology management |
| RISC-V rewriter | `python/riscv_rewrite.py` | Replace calls with CUSTOM_0-3 instructions |
| ARM rewriter | `python/arm_rewrite.py` | Replace calls with UDF/HVC/SMC traps |
| x86_64 rewriter | `python/x86_rewrite.py` | Replace calls with UD2 + payload traps |
| C-to-Verilog | `python/c2v.py` | Convert C functions to synthesizable Verilog |
| Verilator test | `python/c2v_test.py` | Validate Verilog against C via simulation |
| FPGA accelerator | `fpga/rtl/ldx_accel_slave.v` | Avalon-MM slave with c2v function module |
| FPGA top-level | `fpga/rtl/ldx_top.v` | DE2i-150 PCIe system instantiation |
| PCIe BAR bridge | `fpga/rtl/pcie_bar_bridge.v` | BAR0 address decoder for accelerator slots |
| Accelerator slot | `fpga/rtl/accel_slot.v` | Generic register-mapped c2v module wrapper |
| PCIe driver | `src/ldx_pcie.c` | Userspace PCIe BAR access from Atom |
| QSYS system | `fpga/quartus/pcie_system.tcl` | PCIe hard IP + Avalon-MM interconnect |

### Key APIs

**C — Symbol replacement:**
```c
#include "ldx.h"

void *orig = dlreplace("libm.so:sin", my_sin);  // library-qualified
dlreplace("strlen", my_strlen);                   // global
dlreplaceq("str*", callback);                     // pattern + callback
```

**C — Profiling:**
```c
ldx_prof_add("sin");
ldx_prof_add("cos");
// ... run code ...
ldx_prof_report();  // prints call counts, timing
```

**C++ — Pipe abstraction:**
```cpp
#include "ldx_pipe.h"

struct MyArgs {
    int x; double y;
    double invoke(void *fn) const {
        return ((double(*)(int,double))fn)(x, y);
    }
};

// Default: transparent passthrough
ldx::Pipe<MyArgs, double> pipe(original_fn);
double r = pipe.call(MyArgs{42, 3.14});

// Override for network transport, logging, etc.
class NetPipe : public ldx::Pipe<MyArgs, double> {
    double propagate() override { /* send over socket */ }
};
```

**Python — In-process:**
```python
import ldx
ldx.profile_add("sin")
ldx.profile_report()
data = ldx.profile_get()  # list of dicts
entries = ldx.walk_got()   # all GOT entries
```

**Python — Remote control:**
```python
from ldx_ctl import send_cmd
send_cmd("container:9800", {"cmd": "status"})
send_cmd("container:9800", {"cmd": "reconnect", "host": "newhost", "port": 9801})
```

## Generated Syscall Wrappers

`tools/gen_syscall_pbv.py` generates `Pipe<>` wrappers for 53 Linux syscalls:

**File I/O:** read, write, pread, pwrite, close, lseek, dup, dup2, pipe
**Filesystem:** stat, fstat, lstat, access, unlink, rmdir, mkdir, chmod, chown, link, symlink, readlink, rename, truncate, chdir, umask
**Sockets:** socket, bind, connect, listen, shutdown, send, recv, setsockopt
**Memory:** mmap, munmap, mprotect
**Process:** getpid, getppid, getuid, geteuid, getgid, getegid, setuid, setgid, kill
**Other:** epoll_create1, epoll_ctl, gethostname, sethostname

Each syscall gets:
- An `Args` struct with `invoke()`, `syscall_name()`, `write_outbufs()`, `read_outbufs()`
- Local `Pipe<>` typedef (passthrough)
- `SocketPipe<>` typedef (network forwarding)
- Server handler (executes real syscall on host side)

## Binaries

| Binary | Purpose |
|--------|---------|
| `libldx.so` | Core library (LD_PRELOAD or link directly) |
| `libldx_sock.so` | LD_PRELOAD — connects to remote ldx-server |
| `gen/libldx_syscall.so` | LD_PRELOAD — 53 syscall pipe wrappers |
| `ldx` | Bash CLI wrapper |
| `ldx-container` | Container launcher with namespace isolation |
| `ldx-server` | Standalone pipe-os server (TCP) |

## Python Tools

| Tool | Purpose |
|------|---------|
| `python/ldx.py` | ctypes bindings for in-process use |
| `python/ldx_profiler.py` | CLI profiler for unmodified binaries |
| `python/ldx_ctl.py` | Remote control for container migration |
| `python/ldx_controller.py` | REST API for topology/shard management |
| `python/riscv_rewrite.py` | RISC-V binary rewriter (CUSTOM_0-3) |
| `python/arm_rewrite.py` | AArch64 binary rewriter (UDF/HVC/SMC) |
| `python/x86_rewrite.py` | x86_64 binary rewriter (UD2 + payload) |
| `python/c2v.py` | C function → synthesizable Verilog |
| `python/c2v_test.py` | Verilator validation pipeline |
| `tools/gen_syscall_pbv.py` | Generate syscall Pipe<> wrappers |

## Tests

```
test/test_basic       — GOT walking, dlreplace, dlreplaceq
test/test_hooks       — x86_64 trampolines, entry/exit hooks, profiler
test/test_pbv         — serialize/deserialize roundtrip, live PbV shim
test/test_pipe        — Pipe<> passthrough, recording, transform, GOT integration
test/test_syscall_pbv — 53 syscalls through Pipe<> (file I/O, stat, pipe, dup...)
test/test_control     — control socket commands (status, disconnect, suspend...)
test/test_registry    — topology tracking (nodes, shards, functions, routes, migration)
test/test_preload     — LD_PRELOAD on unmodified binary
test/test_remote      — cross-machine syscall forwarding (tested kc-clevo ↔ zmc1)
test/c2v_test.c       — basic c2v functions (add, max, compute, bitwise_blend)
test/c2v_ivl.c        — iverilog 4-state logic (8 functions, 114 Verilator tests)
test/c2v_advanced.c   — shifts, compound ops, parity, popcount, loops (12 functions)
test/c2v_arrays.c     — arrays, casts, CRC step, fib (9 functions)
fpga/test/tb_accel_slot.v  — accelerator slot register read/write (6 tests, iverilog)
fpga/test/tb_pcie_bridge.v — PCIe BAR bridge + slot + globals (7 tests, iverilog)
```

## Examples

```
examples/riscv-accel/  — RISC-V: sin/cos + 4-state logic → CUSTOM_0 instructions
examples/arm-accel/    — AArch64: sin/cos → UDF traps for FPGA SoC
examples/x86-accel/    — x86_64: sin/cos → UD2 traps (runs live with trap handler)
```

## FPGA

Target: DE2i-150 (Intel Atom N2600 + Cyclone IV GX EP4CGX150DF31, PCIe x1 Gen1).

```
fpga/rtl/ldx_top.v            — Top-level: QSYS PCIe system instantiation
fpga/rtl/ldx_accel_slave.v    — Avalon-MM slave: arg registers + c2v function + result
fpga/rtl/ldx_accel_slave_hw.tcl — QSYS component definition
fpga/rtl/add.v                — c2v-generated: add(int, int) → int
fpga/rtl/pcie_bar_bridge.v    — BAR0 address decoder (multi-slot, tested in simulation)
fpga/rtl/accel_slot.v         — Generic c2v module wrapper (tested in simulation)
fpga/quartus/pcie_system.tcl  — QSYS system: PCIe hard IP + Avalon-MM interconnect
fpga/quartus/de2i_150.tcl     — Quartus project setup (device, pins)
fpga/quartus/de2i_150.sdc     — Timing constraints
fpga/quartus/ldx_accel.qpf    — Quartus project file
fpga/quartus/ldx_accel.qsf    — Pin assignments (from Terasic reference design)
fpga/test/tb_accel_slot.v     — Accelerator slot testbench (iverilog)
fpga/test/tb_pcie_bridge.v    — Full-stack testbench (iverilog)
src/ldx_pcie.h                — Userspace PCIe BAR access API
src/ldx_pcie.c                — mmap BAR0, write args, read results
```

Verified end-to-end: `add(42, 58) = 100` computed in FPGA hardware,
called from the Atom over PCIe BAR0. 6 test vectors, all passing.

## Documentation

```
doc/riscv-rewriter.md  — RISC-V call-site rewriter, FPGA prototyping workflow
doc/arm-rewriter.md    — AArch64 rewriter, UDF/HVC/SMC, Zynq/Agilex targets
doc/x86-rewriter.md    — x86_64 rewriter, UD2 trap handler, PCIe FPGA
```

## Relationship to Wandering Threads

This project implements the complementary infrastructure to the [Wandering Threads](https://patents.google.com/patent/US9923840B2) patent (US 9,923,840 B2):

- **Wandering Threads**: move thread execution to where data resides
- **ldx**: move code and data to where execution capacity is available

The combination — threads that follow data, and code that follows available compute — is the full distributed execution model. The `Pipe<>` abstraction is the connection point: override `propagate()` to send execution anywhere.
