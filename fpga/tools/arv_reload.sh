#!/usr/bin/env bash
# arv_reload.sh — JTAG-program the DE2i-150 and re-establish PCIe on the Atom.
#
# Background: on this Atom (ICH7 root port) + Cyclone IV GX combo,
# Linux 6.12 can't recover the PCIe device after the FPGA is
# reprogrammed via JTAG. The link retrains, the BAR survives, but the
# QSYS PCIe HIP completion path stays broken until the host re-enumerates
# at boot. We tried bridge secondary-bus-reset, LnkDisable toggling,
# function-level reset, PMCSR D3→D0, and pci=realloc — none of them
# restore read completions without a reboot.
#
# So this script just automates the only thing that works: program,
# reboot the host, wait for SSH, verify the magic register.
#
# Usage:
#   arv_reload.sh [path/to/file.sof]
#
# Defaults to ../quartus/ldx_accel.sof relative to this script.

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

echo "[1/4] programming $SOF via JTAG..."
PATH="$QUARTUS:$PATH" quartus_pgm \
    -c "$JTAG_CABLE" -m JTAG -o "p;$SOF" 2>&1 | tail -3

echo "[2/4] rebooting Atom ($ATOM)..."
ssh -o ConnectTimeout=5 "$ATOM" "systemctl reboot" || true

echo "[3/4] waiting for Atom to come back..."
sleep 30
for i in 1 2 3 4 5 6; do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "$ATOM" "true" 2>/dev/null; then
        echo "       Atom is up after ~$((30 + (i-1)*5))s"
        break
    fi
    sleep 5
done

echo "[4/4] reading magic register..."
# /root/arv/test.py is the persisted host-side sanity check (see
# fpga/tools/atom_setup/test.py — install once with arv_atom_setup.sh).
ssh "$ATOM" 'python3 /root/arv/test.py'

echo "ready."
