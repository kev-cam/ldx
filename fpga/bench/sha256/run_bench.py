#!/usr/bin/env python3
"""run_bench.py — Load and time SHA-256 on ARV SoC via /dev/mem.

Usage (run on the Atom, or via SSH):
  python3 run_bench.py sha256_sw.bin sha256_cfu.bin
"""
import mmap, struct, time, os, sys

BAR0_PHYS = 0x80000000
BAR0_SIZE = 8192

# BAR0 offsets (word-addressed × 4)
OFF_CTRL   = 0x1F00  # 0x7C0 * 4
OFF_STATUS = 0x1F04  # 0x7C1 * 4
OFF_RESULT = [0x1F08, 0x1F0C, 0x1F10, 0x1F14]  # 0x7C2..7C5
OFF_MAGIC  = 0x1F80  # 0x7E0 * 4

EXPECTED = [0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223]

def run_binary(mm, binpath):
    data = open(binpath, "rb").read()
    nwords = (len(data) + 3) // 4

    def rd(off): return struct.unpack("<I", mm[off:off+4])[0]
    def wr(off, v): mm[off:off+4] = struct.pack("<I", v & 0xFFFFFFFF)

    # Hold reset
    wr(OFF_CTRL, 1)
    time.sleep(0.005)

    # Load binary into RAM (word 0 .. nwords-1)
    for i in range(nwords):
        w = struct.unpack_from("<I", data, i*4)[0] if i*4 < len(data) else 0
        wr(i*4, w)

    # Release reset and time
    t0 = time.perf_counter()
    wr(OFF_CTRL, 0)

    # Poll done
    for _ in range(2000):
        time.sleep(0.001)
        if rd(OFF_STATUS):
            break
    t1 = time.perf_counter()
    elapsed_ms = (t1 - t0) * 1000

    done = rd(OFF_STATUS)
    results = [rd(o) for o in OFF_RESULT]

    ok = done and results == EXPECTED
    return elapsed_ms, results, ok

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <bin1> [bin2 ...]")
        sys.exit(1)

    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    mm = mmap.mmap(fd, BAR0_SIZE, offset=BAR0_PHYS)

    # Verify magic
    magic = struct.unpack("<I", mm[OFF_MAGIC:OFF_MAGIC+4])[0]
    if magic != 0x4C445832:
        print(f"ERROR: magic=0x{magic:08X}, expected 0x4C445832")
        sys.exit(1)

    print(f"{'Binary':<30} {'Time (ms)':>10}  {'Hash[0]':>10}  {'Status':>6}")
    print("-" * 65)

    times = {}
    for binpath in sys.argv[1:]:
        name = os.path.basename(binpath)
        ms, results, ok = run_binary(mm, binpath)
        times[name] = ms
        status = "OK" if ok else "FAIL"
        print(f"{name:<30} {ms:10.1f}  0x{results[0]:08X}  {status}")

    if len(times) >= 2:
        names = list(times.keys())
        t_sw = times[names[0]]
        t_cfu = times[names[1]]
        if t_cfu > 0:
            print(f"\nSpeedup: {t_sw/t_cfu:.2f}x ({names[0]} / {names[1]})")

    os.close(fd)

if __name__ == "__main__":
    main()
