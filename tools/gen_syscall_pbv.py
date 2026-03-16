#!/usr/bin/env python3
"""
gen_syscall_pbv.py — Generate PbV (Pass-by-Value) wrappers and Pipe<> classes
for Linux system calls and libc functions.

Produces:
  gen/ldx_syscall_pbv.h   — Args structs + Pipe typedefs
  gen/ldx_syscall_pbv.cpp — Wrapper functions that route through pipes
  gen/ldx_syscall_pbv.c   — C-only PbV serialize/deserialize for each syscall

Usage:
  python3 tools/gen_syscall_pbv.py
  # builds into gen/ directory, then:
  g++ -shared -fPIC -o gen/libldx_syscall.so gen/ldx_syscall_pbv.cpp -ldl
"""

import os
import sys
from dataclasses import dataclass, field
from typing import List, Optional

# ---------- type system ----------

@dataclass
class Arg:
    name: str
    ctype: str         # C type as written
    direction: str     # "val", "ptr_in", "ptr_out", "ptr_inout"
    size_expr: str = ""  # expression for buffer size (e.g. "n", "sizeof(struct stat)")
    is_string: bool = False

@dataclass
class Syscall:
    name: str
    ret_type: str
    args: List[Arg]
    header: str = "<unistd.h>"
    notes: str = ""
    category: str = "excellent"  # excellent, good, moderate

# ---------- syscall definitions ----------

SYSCALLS = [
    # --- File I/O ---
    Syscall("read", "ssize_t", [
        Arg("fd", "int", "val"),
        Arg("buf", "void *", "ptr_out", size_expr="n"),
        Arg("n", "size_t", "val"),
    ], header="<unistd.h>"),

    Syscall("write", "ssize_t", [
        Arg("fd", "int", "val"),
        Arg("buf", "const void *", "ptr_in", size_expr="n"),
        Arg("n", "size_t", "val"),
    ], header="<unistd.h>"),

    Syscall("pread", "ssize_t", [
        Arg("fd", "int", "val"),
        Arg("buf", "void *", "ptr_out", size_expr="n"),
        Arg("n", "size_t", "val"),
        Arg("offset", "off_t", "val"),
    ], header="<unistd.h>"),

    Syscall("pwrite", "ssize_t", [
        Arg("fd", "int", "val"),
        Arg("buf", "const void *", "ptr_in", size_expr="n"),
        Arg("n", "size_t", "val"),
        Arg("offset", "off_t", "val"),
    ], header="<unistd.h>"),

    Syscall("close", "int", [
        Arg("fd", "int", "val"),
    ], header="<unistd.h>"),

    Syscall("lseek", "off_t", [
        Arg("fd", "int", "val"),
        Arg("offset", "off_t", "val"),
        Arg("whence", "int", "val"),
    ], header="<unistd.h>"),

    Syscall("dup", "int", [
        Arg("fd", "int", "val"),
    ], header="<unistd.h>"),

    Syscall("dup2", "int", [
        Arg("fd", "int", "val"),
        Arg("fd2", "int", "val"),
    ], header="<unistd.h>"),

    Syscall("pipe", "int", [
        Arg("pipedes", "int *", "ptr_out", size_expr="2 * sizeof(int)"),
    ], header="<unistd.h>"),

    # --- File metadata ---
    Syscall("stat", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("buf", "struct stat *", "ptr_out", size_expr="sizeof(struct stat)"),
    ], header="<sys/stat.h>", category="good"),

    Syscall("fstat", "int", [
        Arg("fd", "int", "val"),
        Arg("buf", "struct stat *", "ptr_out", size_expr="sizeof(struct stat)"),
    ], header="<sys/stat.h>", category="good"),

    Syscall("lstat", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("buf", "struct stat *", "ptr_out", size_expr="sizeof(struct stat)"),
    ], header="<sys/stat.h>", category="good"),

    # --- Filesystem ops ---
    Syscall("access", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("mode", "int", "val"),
    ], header="<unistd.h>"),

    Syscall("unlink", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
    ], header="<unistd.h>"),

    Syscall("rmdir", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
    ], header="<unistd.h>"),

    Syscall("mkdir", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("mode", "mode_t", "val"),
    ], header="<sys/stat.h>"),

    Syscall("chmod", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("mode", "mode_t", "val"),
    ], header="<sys/stat.h>"),

    Syscall("fchmod", "int", [
        Arg("fd", "int", "val"),
        Arg("mode", "mode_t", "val"),
    ], header="<sys/stat.h>"),

    Syscall("chown", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("owner", "uid_t", "val"),
        Arg("group", "gid_t", "val"),
    ], header="<unistd.h>"),

    Syscall("fchown", "int", [
        Arg("fd", "int", "val"),
        Arg("owner", "uid_t", "val"),
        Arg("group", "gid_t", "val"),
    ], header="<unistd.h>"),

    Syscall("link", "int", [
        Arg("from_path", "const char *", "ptr_in", is_string=True),
        Arg("to_path", "const char *", "ptr_in", is_string=True),
    ], header="<unistd.h>"),

    Syscall("symlink", "int", [
        Arg("from_path", "const char *", "ptr_in", is_string=True),
        Arg("to_path", "const char *", "ptr_in", is_string=True),
    ], header="<unistd.h>"),

    Syscall("readlink", "ssize_t", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("buf", "char *", "ptr_out", size_expr="len"),
        Arg("len", "size_t", "val"),
    ], header="<unistd.h>"),

    Syscall("chdir", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
    ], header="<unistd.h>"),

    Syscall("fchdir", "int", [
        Arg("fd", "int", "val"),
    ], header="<unistd.h>"),

    Syscall("umask", "mode_t", [
        Arg("mask", "mode_t", "val"),
    ], header="<sys/stat.h>"),

    Syscall("rename", "int", [
        Arg("old_path", "const char *", "ptr_in", is_string=True),
        Arg("new_path", "const char *", "ptr_in", is_string=True),
    ], header="<stdio.h>"),

    Syscall("truncate", "int", [
        Arg("path", "const char *", "ptr_in", is_string=True),
        Arg("length", "off_t", "val"),
    ], header="<unistd.h>"),

    Syscall("ftruncate", "int", [
        Arg("fd", "int", "val"),
        Arg("length", "off_t", "val"),
    ], header="<unistd.h>"),

    # --- Socket ops ---
    Syscall("socket", "int", [
        Arg("domain", "int", "val"),
        Arg("type", "int", "val"),
        Arg("protocol", "int", "val"),
    ], header="<sys/socket.h>"),

    Syscall("bind", "int", [
        Arg("fd", "int", "val"),
        Arg("addr", "const struct sockaddr *", "ptr_in", size_expr="len"),
        Arg("len", "socklen_t", "val"),
    ], header="<sys/socket.h>", category="good"),

    Syscall("connect", "int", [
        Arg("fd", "int", "val"),
        Arg("addr", "const struct sockaddr *", "ptr_in", size_expr="len"),
        Arg("len", "socklen_t", "val"),
    ], header="<sys/socket.h>", category="good"),

    Syscall("listen", "int", [
        Arg("fd", "int", "val"),
        Arg("backlog", "int", "val"),
    ], header="<sys/socket.h>"),

    Syscall("shutdown", "int", [
        Arg("fd", "int", "val"),
        Arg("how", "int", "val"),
    ], header="<sys/socket.h>"),

    Syscall("send", "ssize_t", [
        Arg("fd", "int", "val"),
        Arg("buf", "const void *", "ptr_in", size_expr="n"),
        Arg("n", "size_t", "val"),
        Arg("flags", "int", "val"),
    ], header="<sys/socket.h>"),

    Syscall("recv", "ssize_t", [
        Arg("fd", "int", "val"),
        Arg("buf", "void *", "ptr_out", size_expr="n"),
        Arg("n", "size_t", "val"),
        Arg("flags", "int", "val"),
    ], header="<sys/socket.h>"),

    Syscall("setsockopt", "int", [
        Arg("fd", "int", "val"),
        Arg("level", "int", "val"),
        Arg("optname", "int", "val"),
        Arg("optval", "const void *", "ptr_in", size_expr="optlen"),
        Arg("optlen", "socklen_t", "val"),
    ], header="<sys/socket.h>", category="good"),

    # --- Memory management ---
    Syscall("mmap", "void *", [
        Arg("addr", "void *", "val"),
        Arg("len", "size_t", "val"),
        Arg("prot", "int", "val"),
        Arg("flags", "int", "val"),
        Arg("fd", "int", "val"),
        Arg("offset", "off_t", "val"),
    ], header="<sys/mman.h>"),

    Syscall("munmap", "int", [
        Arg("addr", "void *", "val"),
        Arg("len", "size_t", "val"),
    ], header="<sys/mman.h>"),

    Syscall("mprotect", "int", [
        Arg("addr", "void *", "val"),
        Arg("len", "size_t", "val"),
        Arg("prot", "int", "val"),
    ], header="<sys/mman.h>"),

    # --- Process ---
    Syscall("getpid", "pid_t", [], header="<unistd.h>"),
    Syscall("getppid", "pid_t", [], header="<unistd.h>"),
    Syscall("getuid", "uid_t", [], header="<unistd.h>"),
    Syscall("geteuid", "uid_t", [], header="<unistd.h>"),
    Syscall("getgid", "gid_t", [], header="<unistd.h>"),
    Syscall("getegid", "gid_t", [], header="<unistd.h>"),

    Syscall("setuid", "int", [Arg("uid", "uid_t", "val")], header="<unistd.h>"),
    Syscall("setgid", "int", [Arg("gid", "gid_t", "val")], header="<unistd.h>"),

    Syscall("kill", "int", [
        Arg("pid", "pid_t", "val"),
        Arg("sig", "int", "val"),
    ], header="<signal.h>"),

    # --- Epoll ---
    Syscall("epoll_create1", "int", [
        Arg("flags", "int", "val"),
    ], header="<sys/epoll.h>"),

    Syscall("epoll_ctl", "int", [
        Arg("epfd", "int", "val"),
        Arg("op", "int", "val"),
        Arg("fd", "int", "val"),
        Arg("event", "struct epoll_event *", "ptr_in", size_expr="sizeof(struct epoll_event)"),
    ], header="<sys/epoll.h>", category="good"),

    # --- Misc ---
    Syscall("gethostname", "int", [
        Arg("name", "char *", "ptr_out", size_expr="len"),
        Arg("len", "size_t", "val"),
    ], header="<unistd.h>"),

    Syscall("sethostname", "int", [
        Arg("name", "const char *", "ptr_in", size_expr="len"),
        Arg("len", "size_t", "val"),
    ], header="<unistd.h>"),
]

# ---------- code generation ----------

def struct_name(sc: Syscall) -> str:
    return f"ldx_sc_{sc.name}_args"

def pipe_name(sc: Syscall) -> str:
    return f"ldx_sc_{sc.name}_pipe_t"

def val_type(arg: Arg) -> str:
    """Type for storing this arg by value in the struct."""
    # Keep the original type — const pointers stay const
    return arg.ctype

def needs_buffer(arg: Arg) -> bool:
    return arg.direction in ("ptr_in", "ptr_out", "ptr_inout")

def gen_header(syscalls: List[Syscall]) -> str:
    lines = []
    lines.append("/* AUTO-GENERATED by gen_syscall_pbv.py — do not edit */")
    lines.append("#ifndef LDX_SYSCALL_PBV_H")
    lines.append("#define LDX_SYSCALL_PBV_H")
    lines.append("")
    lines.append("#include <stddef.h>")
    lines.append("#include <stdint.h>")
    lines.append("#include <sys/types.h>")
    lines.append("#include <sys/stat.h>")
    lines.append("#include <sys/socket.h>")
    lines.append("#include <sys/epoll.h>")
    lines.append("#include <sys/mman.h>")
    lines.append("#include <signal.h>")
    lines.append("#include <unistd.h>")
    lines.append("#include <fcntl.h>")
    lines.append("")

    # C++ section
    lines.append("#ifdef __cplusplus")
    lines.append('#include "ldx_pipe.h"')
    lines.append("")

    for sc in syscalls:
        # Args struct
        lines.append(f"/* {sc.name}() — {sc.category} candidate */")
        lines.append(f"struct {struct_name(sc)} {{")
        for arg in sc.args:
            lines.append(f"    {val_type(arg)} {arg.name};")
        lines.append("")

        # invoke() method
        ret = sc.ret_type
        args_list = ", ".join(f"this->{a.name}" for a in sc.args)
        proto_args = ", ".join(f"{a.ctype}" for a in sc.args)

        if ret == "void":
            lines.append(f"    void invoke(void *fn) const {{")
            lines.append(f"        (({ret}(*)({proto_args}))fn)({args_list});")
        else:
            lines.append(f"    {ret} invoke(void *fn) const {{")
            lines.append(f"        return (({ret}(*)({proto_args}))fn)({args_list});")
        lines.append(f"    }}")
        lines.append(f"}};")
        lines.append(f"typedef ldx::Pipe<{struct_name(sc)}, {ret}> {pipe_name(sc)};")
        lines.append("")

    lines.append("#endif /* __cplusplus */")
    lines.append("")

    # C interface — original function pointers and pipe-through wrappers
    lines.append("#ifdef __cplusplus")
    lines.append('extern "C" {')
    lines.append("#endif")
    lines.append("")
    lines.append("/* Install PbV pipe wrappers for all supported syscalls.")
    lines.append(" * Original functions are saved and called through Pipe<>::propagate(). */")
    lines.append("int ldx_syscall_pbv_init(void);")
    lines.append("")
    lines.append("/* Get count of installed wrappers. */")
    lines.append("int ldx_syscall_pbv_count(void);")
    lines.append("")
    lines.append("#ifdef __cplusplus")
    lines.append("}")
    lines.append("#endif")
    lines.append("")
    lines.append("#endif /* LDX_SYSCALL_PBV_H */")

    return "\n".join(lines) + "\n"

def gen_cpp(syscalls: List[Syscall]) -> str:
    lines = []
    lines.append("/* AUTO-GENERATED by gen_syscall_pbv.py — do not edit */")
    lines.append('#include "ldx_syscall_pbv.h"')
    lines.append("")
    lines.append("extern \"C\" {")
    lines.append('#include "ldx.h"')
    lines.append("}")
    lines.append("")
    lines.append("#include <cstdio>")
    lines.append("#include <cstring>")
    lines.append("#include <dlfcn.h>")
    lines.append("")

    # For each syscall, create:
    # 1. A static Pipe instance
    # 2. A wrapper function with the original signature
    # 3. Init code to save original + patch GOT

    lines.append("/* --- Pipe instances --- */")
    lines.append("")
    for sc in syscalls:
        lines.append(f"static {pipe_name(sc)} *sc_pipe_{sc.name} = nullptr;")
    lines.append("")

    lines.append("/* --- Wrapper functions --- */")
    lines.append("")

    for sc in syscalls:
        ret = sc.ret_type
        proto_args = ", ".join(f"{a.ctype} {a.name}" for a in sc.args)
        if not proto_args:
            proto_args = "void"

        lines.append(f"static {ret} wrap_{sc.name}({proto_args})")
        lines.append("{")

        # Build args struct
        arg_init = ", ".join(a.name for a in sc.args)
        if sc.args:
            lines.append(f"    {struct_name(sc)} args = {{{arg_init}}};")
        else:
            lines.append(f"    {struct_name(sc)} args = {{}};")

        if ret == "void":
            lines.append(f"    sc_pipe_{sc.name}->call(args);")
        else:
            lines.append(f"    return sc_pipe_{sc.name}->call(args);")

        lines.append("}")
        lines.append("")

    # Init function
    lines.append("/* --- Init: save originals, create pipes, patch GOT --- */")
    lines.append("")
    lines.append("static int installed_count = 0;")
    lines.append("")
    lines.append("extern \"C\" int ldx_syscall_pbv_init(void)")
    lines.append("{")
    lines.append("    ldx_init();")
    lines.append("    void *orig;")
    lines.append("")

    for sc in syscalls:
        lines.append(f"    /* {sc.name} */")
        lines.append(f"    orig = dlsym(RTLD_NEXT, \"{sc.name}\");")
        lines.append(f"    if (orig) {{")
        lines.append(f"        sc_pipe_{sc.name} = new {pipe_name(sc)}(orig);")
        lines.append(f"        dlreplace(\"{sc.name}\", (void *)wrap_{sc.name});")
        lines.append(f"        installed_count++;")
        lines.append(f"    }}")
        lines.append("")

    lines.append(f"    fprintf(stderr, \"ldx: installed %d syscall PbV wrappers\\n\", installed_count);")
    lines.append("    return installed_count;")
    lines.append("}")
    lines.append("")
    lines.append("extern \"C\" int ldx_syscall_pbv_count(void)")
    lines.append("{")
    lines.append("    return installed_count;")
    lines.append("}")
    lines.append("")

    return "\n".join(lines) + "\n"

# ---------- main ----------

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    gen_dir = os.path.join(project_dir, "gen")
    os.makedirs(gen_dir, exist_ok=True)

    header = gen_header(SYSCALLS)
    cpp = gen_cpp(SYSCALLS)

    h_path = os.path.join(gen_dir, "ldx_syscall_pbv.h")
    cpp_path = os.path.join(gen_dir, "ldx_syscall_pbv.cpp")

    with open(h_path, "w") as f:
        f.write(header)
    with open(cpp_path, "w") as f:
        f.write(cpp)

    print(f"Generated {len(SYSCALLS)} syscall wrappers:")
    for cat in ("excellent", "good", "moderate"):
        count = sum(1 for s in SYSCALLS if s.category == cat)
        if count:
            print(f"  {cat}: {count}")
    print(f"\nFiles:")
    print(f"  {h_path}")
    print(f"  {cpp_path}")
    print(f"\nBuild:")
    print(f"  make gen")


if __name__ == "__main__":
    main()
