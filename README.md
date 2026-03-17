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

## Tests

```
test/test_basic      — GOT walking, dlreplace, dlreplaceq
test/test_hooks      — x86_64 trampolines, entry/exit hooks, profiler
test/test_pbv        — serialize/deserialize roundtrip, live PbV shim
test/test_pipe       — Pipe<> passthrough, recording, transform, GOT integration
test/test_syscall_pbv — 53 syscalls through Pipe<> (file I/O, stat, pipe, dup...)
test/test_control    — control socket commands (status, disconnect, suspend...)
test/test_registry   — topology tracking (nodes, shards, functions, routes, migration)
test/test_preload    — LD_PRELOAD on unmodified binary
test/test_remote     — cross-machine syscall forwarding (tested kc-clevo ↔ zmc1)
```

## Relationship to Wandering Threads

This project implements the complementary infrastructure to the [Wandering Threads](https://patents.google.com/patent/US9923840B2) patent (US 9,923,840 B2):

- **Wandering Threads**: move thread execution to where data resides
- **ldx**: move code and data to where execution capacity is available

The combination — threads that follow data, and code that follows available compute — is the full distributed execution model. The `Pipe<>` abstraction is the connection point: override `propagate()` to send execution anywhere.
