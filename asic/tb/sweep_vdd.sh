#!/bin/bash
# sweep_vdd.sh — test NN-hybrid vs IV-table 4-bit adders across VDD.
# Reports mismatch count per VDD point.

set -e
CELLS=/usr/local/src/ldx/asic/cells
TB=/usr/local/src/ldx/asic/tb
LIB=/usr/local/src/nvc/lib/sv2vhdl
NCL=/usr/local/src/ldx/fpga/lib/ncl_sync

cd /tmp

printf "%6s %15s %15s\n" "VDD_V" "NN_mismatches" "EVT_mismatches"

for vdd in 0.80 0.90 1.00 1.10 1.20 1.30 1.40; do
  # Regenerate source at this VDD
  sed "s|constant VDD_V : real := 1.2;|constant VDD_V : real := $vdd;|" \
      $TB/tb_ncl_add4_nn_assert.vhd > /tmp/tb_nn_sweep.vhd
  sed -i 's|tb_ncl_add4_nn_assert|tb_nn_sweep|g' /tmp/tb_nn_sweep.vhd

  sed "s|constant VDD_V : real := 1.2;|constant VDD_V : real := $vdd;|" \
      $TB/tb_ncl_add4_assert_correct.vhd > /tmp/tb_evt_sweep.vhd
  sed -i 's|tb_ncl_add4_assert_correct|tb_evt_sweep|g' /tmp/tb_evt_sweep.vhd

  rm -rf work
  nvc --std=08 -a $NCL/ncl.vhdl $LIB/logic3d_types_pkg.vhd \
      $LIB/logic3ds_pkg.vhd $LIB/logic3da_pkg.vhd \
      $CELLS/th22_nn_hybrid.vhd $CELLS/th23_nn_hybrid.vhd \
      $CELLS/th34w2_nn_hybrid.vhd $CELLS/nclfa_nn_hybrid.vhd \
      $CELLS/th23_hybrid_evt.vhd $CELLS/th34w2_hybrid_evt.vhd \
      $CELLS/nclfa_hybrid_evt.vhd \
      /tmp/tb_nn_sweep.vhd /tmp/tb_evt_sweep.vhd 2>/dev/null

  nvc --std=08 -e tb_nn_sweep 2>/dev/null
  nn_m=$(nvc --std=08 -r tb_nn_sweep 2>&1 | grep -cE "MISMATCH")

  nvc --std=08 -e tb_evt_sweep 2>/dev/null
  evt_m=$(nvc --std=08 -r tb_evt_sweep 2>&1 | grep -cE "MISMATCH")

  printf "%6s %15d %15d\n" "$vdd" "$nn_m" "$evt_m"
done
