"""
ldx — Python bindings for the programmable linker library.

Two usage modes:

1. In-process: import ldx in a Python program that has libldx.so loaded
   (via LD_PRELOAD or ctypes). Call ldx.replace(), ldx.profile(), etc.

2. CLI profiler: run `python -m ldx --profile sin,cos,strlen ./mybinary`
   to profile an unmodified binary.
"""

import ctypes
import ctypes.util
import os
import json
import sys
from pathlib import Path

# ---------- library loading ----------

_lib = None

def _find_libldx():
    """Find libldx.so — check common locations."""
    candidates = [
        os.environ.get("LDX_LIB", ""),
        str(Path(__file__).parent.parent / "libldx.so"),
        "libldx.so",
        "/usr/local/lib/libldx.so",
    ]
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    return None

def _load():
    global _lib
    if _lib is not None:
        return _lib

    path = _find_libldx()
    if not path:
        raise RuntimeError(
            "Cannot find libldx.so. Set LDX_LIB env var or build with 'make'."
        )

    _lib = ctypes.CDLL(path)

    # void ldx_init(void)
    _lib.ldx_init.restype = None
    _lib.ldx_init.argtypes = []

    # void *dlreplace(const char *target, void *replacement)
    _lib.dlreplace.restype = ctypes.c_void_p
    _lib.dlreplace.argtypes = [ctypes.c_char_p, ctypes.c_void_p]

    # int dlreplaceq(const char *pattern, callback)
    REPLACEQ_CB = ctypes.CFUNCTYPE(
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p
    )
    _lib.dlreplaceq.restype = ctypes.c_int
    _lib.dlreplaceq.argtypes = [ctypes.c_char_p, REPLACEQ_CB]

    # int ldx_prof_add(const char *target)
    _lib.ldx_prof_add.restype = ctypes.c_int
    _lib.ldx_prof_add.argtypes = [ctypes.c_char_p]

    # void ldx_prof_report(void)
    _lib.ldx_prof_report.restype = None
    _lib.ldx_prof_report.argtypes = []

    # void ldx_prof_reset(void)
    _lib.ldx_prof_reset.restype = None
    _lib.ldx_prof_reset.argtypes = []

    # int ldx_walk_got(callback, void *user)
    WALK_CB = ctypes.CFUNCTYPE(
        ctypes.c_int,
        ctypes.c_char_p, ctypes.c_char_p,
        ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p, ctypes.c_void_p
    )
    _lib.ldx_walk_got.restype = ctypes.c_int
    _lib.ldx_walk_got.argtypes = [WALK_CB, ctypes.c_void_p]

    # Hook callback type
    HOOK_CB = ctypes.CFUNCTYPE(
        None,
        ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_int, ctypes.c_ulong, ctypes.c_double
    )
    _lib.ldx_add_hook.restype = ctypes.c_int
    _lib.ldx_add_hook.argtypes = [ctypes.c_char_p, HOOK_CB]

    # Prof entry struct
    class LdxProfEntry(ctypes.Structure):
        _fields_ = [
            ("sym", ctypes.c_char_p),
            ("lib", ctypes.c_char_p),
            ("call_count", ctypes.c_ulong),
            ("total_time", ctypes.c_double),
            ("min_time", ctypes.c_double),
            ("max_time", ctypes.c_double),
        ]

    _lib.ldx_prof_get.restype = ctypes.c_int
    _lib.ldx_prof_get.argtypes = [ctypes.POINTER(LdxProfEntry), ctypes.c_int]

    _lib._LdxProfEntry = LdxProfEntry
    _lib._HOOK_CB = HOOK_CB
    _lib._WALK_CB = WALK_CB
    _lib._REPLACEQ_CB = REPLACEQ_CB

    _lib.ldx_init()
    return _lib


# ---------- public API ----------

def replace(target, replacement_ptr):
    """Replace a symbol's GOT entries with a new function pointer.

    target: "strlen" or "libm.so:sin"
    replacement_ptr: integer address of the replacement function

    Returns the original function pointer (as int), or None.
    """
    lib = _load()
    orig = lib.dlreplace(target.encode(), ctypes.c_void_p(replacement_ptr))
    return orig


def walk_got():
    """Walk all GOT entries. Returns list of (symbol, library, slot_addr, value)."""
    lib = _load()
    results = []

    @lib._WALK_CB
    def cb(sym, libname, slot, val, user):
        results.append((
            sym.decode() if sym else "",
            libname.decode() if libname else "",
            ctypes.addressof(slot.contents) if slot else 0,
            val or 0,
        ))
        return 0

    lib.ldx_walk_got(cb, None)
    return results


def profile_add(target):
    """Add a symbol to the profiler. Returns 0 on success."""
    lib = _load()
    return lib.ldx_prof_add(target.encode())


def profile_report():
    """Print profiling report to stderr."""
    lib = _load()
    lib.ldx_prof_report()


def profile_get():
    """Get profiling data as list of dicts."""
    lib = _load()
    entries = (lib._LdxProfEntry * 256)()
    n = lib.ldx_prof_get(entries, 256)
    results = []
    for i in range(n):
        e = entries[i]
        results.append({
            "sym": e.sym.decode() if e.sym else "",
            "lib": e.lib.decode() if e.lib else "",
            "call_count": e.call_count,
            "total_time": e.total_time,
            "min_time": e.min_time,
            "max_time": e.max_time,
        })
    return results


def profile_reset():
    """Reset all profiling counters."""
    lib = _load()
    lib.ldx_prof_reset()


def add_hook(target, callback):
    """Register an entry/exit hook for target.

    callback(sym: str, lib: str, is_exit: bool, thread_id: int, timestamp: float)

    Note: The callback object must be kept alive (stored in a variable)
    for the duration of the hook, otherwise it will be garbage collected.

    Returns (status_code, prevent_gc_ref).
    """
    lib = _load()

    @lib._HOOK_CB
    def c_cb(sym, libname, is_exit, tid, ts):
        callback(
            sym.decode() if sym else "",
            libname.decode() if libname else "",
            bool(is_exit), tid, ts,
        )

    rc = lib.ldx_add_hook(target.encode(), c_cb)
    return rc, c_cb  # caller must hold c_cb reference
