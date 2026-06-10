#!/bin/bash
# gen_core_variants.sh — generate per-core feature-matrix variants on demand.
# Each variant is shifter:muldiv:cfu. Output: core_lib/VexRiscv_<name>.v
# Usage:  ./gen_core_variants.sh [barrel:on:on light:off:off ...]
#         (no args -> the common set below)
set -e
VEX=/usr/local/src/vexriscv
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/core_lib"; mkdir -p "$OUT"
cp "$HERE/GenLdxCpu.scala" "$VEX/src/main/scala/vexriscv/demo/GenLdxCpu.scala"   # keep generator in sync

VARS=("$@")
[ ${#VARS[@]} -eq 0 ] && VARS=(barrel:on:on barrel:off:on barrel:off:off light:off:off)
for v in "${VARS[@]}"; do
  IFS=: read -r sh md cf <<< "$v"
  nm="VexRiscv_${sh}_$([ "$md" = on ] && echo mul || echo nomul)_$([ "$cf" = on ] && echo cfu || echo nocfu)"
  ( cd "$VEX" && sbt "runMain vexriscv.demo.GenLdxCpu shifter=$sh muldiv=$md cfu=$cf" ) >/dev/null 2>&1
  cp "$VEX/VexRiscv.v" "$OUT/$nm.v"
  printf "%-34s %5d lines\n" "$nm.v" "$(wc -l < "$OUT/$nm.v")"
done
echo "core_lib/ populated — point create_8x8_project.tcl (set rtl .../core_lib/<variant>.v) at the chosen core."
