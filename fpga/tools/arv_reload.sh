#!/usr/bin/env bash
# arv_reload.sh — JTAG-program the DE2i-150 and recover PCIe without rebooting.
#
# After JTAG reprogramming, the host's PCIe view goes stale (reads return
# 0xFFFFFFFF). Recovery without reboot:
#   1. Remove the stale device from the kernel PCI tree
#   2. Rescan — kernel re-discovers the device (BAR stays unassigned)
#   3. Write BAR0 = 0x80000000 and enable Mem+BusMaster via setpci
#   4. Access via /dev/mem at physical 0x80000000
#
# Usage:
#   arv_reload.sh [path/to/file.sof]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOF="${1:-$SCRIPT_DIR/../quartus/ldx_accel.sof}"
ATOM="${ATOM:-root@192.168.15.153}"
QUARTUS="${QUARTUS:-/home/dkc/altera_lite/25.1std/quartus/bin}"
JTAG_CABLE="${JTAG_CABLE:-USB-Blaster [2-1.5]}"

if [[ ! -f "$SOF" ]]; then
    echo "error: bitstream not found: $SOF" >&2
    exit 1
fi

echo "[1/3] programming $SOF via JTAG..."
PATH="$QUARTUS:$PATH" quartus_pgm \
    -c "$JTAG_CABLE" -m JTAG -o "p;$SOF" 2>&1 | tail -3

echo "[2/3] recovering host PCIe..."
# Give the FPGA time to finish configuring and train the PCIe link
sleep 3
ssh -o ConnectTimeout=10 "$ATOM" 'bash -s' << 'REMOTE'
set -e
DEV="01:00.0"
SYSDEV="/sys/bus/pci/devices/0000:$DEV"

# Step 1: remove stale device (if it exists)
if [ -e "$SYSDEV/remove" ]; then
    echo "  removing stale device..."
    echo 1 > "$SYSDEV/remove"
    sleep 2
fi

# Step 2: rescan — kernel finds fresh device
echo "  rescanning PCI bus..."
echo 1 > /sys/bus/pci/rescan
sleep 3

# Step 3: manually assign BAR0 and enable
if [ -e "$SYSDEV" ]; then
    echo "  assigning BAR0 = 0x80000000..."
    setpci -s "$DEV" BASE_ADDRESS_0=0x8000000C
    setpci -s "$DEV" BASE_ADDRESS_1=0x00000000
    setpci -s "$DEV" COMMAND=0x0006
else
    echo "  ERROR: device not found after rescan" >&2
    exit 1
fi
REMOTE

echo "[3/3] verifying via /dev/mem..."
ssh "$ATOM" 'python3 << "PY"
import mmap, struct, os, sys
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, 8192, offset=0x80000000)
m = struct.unpack("<I", mm[0x1F80:0x1F84])[0]
r = struct.unpack("<I", mm[0x1F00:0x1F04])[0]
d = struct.unpack("<I", mm[0x1F04:0x1F08])[0]
ok = "OK" if m == 0x4C445832 else "FAIL"
print(f"  magic=0x{m:08X} ({ok})  reset={r}  done={d}")
os.close(fd)
sys.exit(0 if m == 0x4C445832 else 1)
PY'

echo "ready."
