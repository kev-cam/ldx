#!/bin/sh
# run.sh — milestone-1 hello-world on ZCU104 PetaLinux.
# Run as root after extracting the bundle. Requires: the .bit.bin in /lib/firmware/,
# and ldx_daemon + hello.bin in CWD.
set -e

BIT="${BIT:-system_wrapper.bit.bin}"
FW_DST="/lib/firmware/$BIT"

if [ ! -f "$FW_DST" ]; then
    if [ -f "$BIT" ]; then
        cp "$BIT" "$FW_DST"
    else
        echo "missing bitstream: $BIT" >&2; exit 1
    fi
fi

# Switch fpga_manager to partial=0 (full reconfig) and load
FM=/sys/class/fpga_manager/fpga0
echo 0 > $FM/flags
echo "$BIT" > $FM/firmware
sleep 1
STATE=$(cat $FM/state)
echo "fpga_manager state: $STATE"
case "$STATE" in
    operating) ;;
    *) echo "FPGA not operating, aborting"; exit 1;;
esac

# Run the daemon. It mmaps 0xA0000000, loads hello.bin into BRAM,
# releases the softcore, and relays mailbox bytes to stdout.
exec ./ldx_daemon hello.bin
