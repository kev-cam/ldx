#!/usr/bin/env bash
# Install host-side ARV PCIe sanity scripts to /root/arv/ on the Atom.
set -euo pipefail
ATOM="${ATOM:-root@192.168.15.153}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ssh "$ATOM" "mkdir -p /root/arv"
scp "$HERE/test.py" "$ATOM:/root/arv/test.py"
ssh "$ATOM" "chmod +x /root/arv/test.py && ls -la /root/arv/"
