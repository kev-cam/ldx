# Programmable Linker: Student Project Description

## Project Title

**Dynamic Code Replumbing via Programmable Linux Linker Extensions**

## Motivation

The Linux dynamic linker (`ld.so`) is one of the most underexplored leverage points in the software stack. It resolves symbols, loads shared libraries, and wires up function calls — but it does all of this as a fixed, opaque process. There is no clean mechanism for a running program to say "from now on, when `libfoo:bar()` is called, call this other function instead" or "tell me every time `main→f1→f2` is invoked and how long it takes."

This project makes the linker programmable. The immediate payoff is a profiling and optimization tool. The long-term payoff is the infrastructure for automatic code sharding — moving groups of functions into separate containers and connecting them over networks, transparently, without modifying the original source code. This is the plumbing layer for the Wandering Threads distributed execution model (US Patent 9,923,840 B2).

## Overview

The project is structured in two phases. Phase 1 builds the core linker control mechanism and proves it with a profiler. Phase 2 uses that mechanism to begin distributing code across containers and heterogeneous platforms.

---

## Phase 1 — Programmable Linker Control

### 1.1 Mechanism

Use `LD_PRELOAD` to inject a shared library that intercepts the dynamic linking process. This library exposes new linker control functions callable from C, with a Python scripting layer on top for dynamic configuration.

### 1.2 New Linker Control Functions

**`dlreplace(target, replacement)`** — Global symbol replacement.

The `target` and `replacement` arguments use a naming scheme that supports two granularities:

- **Library-qualified names**: `"libmath.so:sin"` — replace all calls to `sin` resolved from `libmath.so` with the replacement function. This is a global, unconditional swap.
- **Call-path names**: `"main…f1…f2"` — replace only the instance of `f2` that is reached via the call path `main→f1→f2`. Other call sites to `f2` remain unaffected. Implementation requires shim insertion at the call-path boundary, not just symbol table rewriting.

**`dlreplaceq(pattern, callback)`** — Query-based replacement with callback.

Rather than specifying the replacement at registration time, this registers a C callback (bridged to Python) that is invoked when a matching symbol is about to be resolved. The callback receives the symbol name and context, and returns the address of the replacement function (or NULL to keep the original). This enables policy-driven replacement — the Python layer can consult configuration files, runtime conditions, or external services to decide what to substitute.

**`dlreplace` (runtime variant)** — Same semantics as above, but callable after the program has started execution, not just at load time. This requires patching live PLT/GOT entries or installed shims rather than intercepting initial resolution.

### 1.3 Instrumentation Callbacks

Selected routines (either replaced or shimmed) can have callbacks registered that fire on entry and/or exit. The callback receives:

- Function identity (library, symbol, call-path if applicable)
- Wall-clock time at entry and exit
- Thread identity
- Caller identity

These callbacks route from C shims into the Python control layer, enabling scripted analysis of runtime behavior without recompilation.

### 1.4 First Deliverable: Shim Profiler

A complete application built on the above primitives:

- User provides a Python configuration specifying which functions to instrument
- The profiler injects shims via `dlreplace` that collect timing data via callbacks
- Output includes per-function call counts, cumulative and per-call wall-clock time, call-graph edges with timing, and hot-path identification
- The profiler can be attached to unmodified binaries — no recompilation, no source access required

### 1.5 Branch Prediction Hints

As an extension to the profiler, use collected branch-frequency data to experiment with inserting `__builtin_expect` hints (see [GCC Other Builtins](https://gcc.gnu.org/onlinedocs/gcc/Other-Builtins.html)) into recompiled versions of hot functions. The workflow is: profile with shims → identify branch-heavy hot functions → generate annotated source or LLVM IR with expect hints → measure improvement. This closes the loop between runtime observation and compile-time optimization.

---

## Phase 2 — Code Sharding and Distribution

Phase 2 uses the Phase 1 infrastructure to begin moving code off the local machine.

### 2.1 Pass-by-Value Conversion

Create new versions of selected routines that accept arguments by value (PbV) instead of by reference (PbR). Use `dlreplace` shims to intercept calls to the original PbR routines, dereference the pointer arguments, and forward to the PbV copies. This is the prerequisite for network transport — you can't send a pointer over a socket, but you can send a value.

### 2.2 Network Insertion

For functions that have been fully converted to PbV (all arguments and return values are values, not pointers into shared state), insert IPv6 socket pairs into the call/return path. The shim serializes arguments, sends them over the socket, waits for the return value, and deserializes it. From the caller's perspective, nothing has changed — it's still a function call.

### 2.3 Metrics and Observability

Extend the Phase 1 callback mechanism to cover the new shim/socket/channel infrastructure. Log data transfer sizes, serialization overhead, network latency, and end-to-end call time. This data feeds back into placement decisions — if a network call is slower than local execution, the shim can be removed or the function relocated.

### 2.4 Container Placement

Group functions that share state (PbR clusters) into the same container. Functions that have been converted to PbV can be placed in separate containers. Key principles:

- Containers are created to hold **data or state**, not just code. The code follows the data.
- Multiple containers may hold the same code group but with different data (think: sharded instances of the same service operating on different partitions).
- Use container topology information to steer memory allocation — this connects to the Wandering Thread allocator steering concept, where the allocator places data near the code that will access it.

### 2.5 Container Mobility

Detach containers and move them in the virtual network space. This is where the IPv6 socket abstraction pays off — moving a container to a different machine changes the socket endpoint, not the calling code.

For SMP (shared-memory multiprocessor) environments, use memory-to-core mapping instead of sockets. For computational storage, clone the container to the storage device. Add a return mechanism for program suspension and resumption when containers are migrated.

### 2.6 Heterogeneous Platforms

The socket abstraction is ISA-agnostic. Target configurations include:

- x86 host with ARM computational storage
- Linux host with DD-WRT network servers as compute nodes

The PbV conversion and socket insertion make cross-ISA execution transparent — the calling convention is "serialize, send, receive, deserialize" regardless of what ISA executes the function.

### 2.7 Target Applications

Prove the system on real workloads:

- **MySQL** — shard query processing across containers, move hot tables to computational storage
- **ZoneMinder** — distribute video processing pipeline stages across heterogeneous nodes

### 2.8 Optimizations

Once the system is running and instrumented:

- **Undo unnecessary shims** — where profiling shows a function will never be migrated, remove the shim overhead and link directly
- **Short-circuit sockets** — when two containers are co-located (same machine, same memory space), replace the socket path with direct function calls or shared-memory IPC

---

## What This Is Not

This project does not require modifying the Linux kernel, the GCC/LLVM toolchain, or the `ld.so` source code. Everything operates in userspace via `LD_PRELOAD`, `dlsym`, PLT/GOT manipulation, and standard socket APIs. The sophistication is in the orchestration layer (Python) and the shim generation, not in kernel hacking.

## Relationship to Wandering Threads

The Wandering Threads patent (US 9,923,840 B2) describes moving thread execution to where data resides. This project builds the complementary infrastructure: moving **code and data** to where execution capacity is available. The combination — threads that follow data, and code that follows available compute — is the full distributed execution model.

## Prerequisites

- Solid C programming (shims, `dlsym`, `LD_PRELOAD` mechanics)
- Python (orchestration, configuration, analysis)
- Understanding of ELF format, PLT/GOT, dynamic linking basics
- Linux systems programming (sockets, containers, process management)
- Familiarity with profiling concepts and call-graph analysis
