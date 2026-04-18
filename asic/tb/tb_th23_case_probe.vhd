-- tb_th23_case_probe.vhd — Single IV-table TH23 cell with the exact
-- input sequence seen by bit-1 coL in the 2-bit adder case 1+1+0:
--   NULL (all 0) → DATA (V,V,V) → NULL → DATA (V,V,0)
-- If this cell fires on the final (V,V,0) case as expected, the bug
-- in the 2-bit adder is in the multi-cell wiring; if it doesn't, the
-- bug is in the cell itself.

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_th23_case_probe is
end entity;

architecture sim of tb_th23_case_probe is
  constant Z : logic3da := (voltage => 0.0, resistance => 0.0, flags => AFL_KNOWN);
  constant HI : logic3da := (voltage => 1.2, resistance => 0.0, flags => AFL_KNOWN);

  signal A, B, C : resolved_logic3da := Z;
  signal VDD : resolved_logic3da := (voltage => 1.2, resistance => 0.0, flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := Z;
  signal Y_drv, vdd_drv : logic3da := Z;
  signal Y_cap : real := 0.0;
begin
  VDD <= (voltage => 1.2, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= Z;

  dut : entity work.th23_hybrid_evt
    port map (A => A, B => B, C => C,
              VDD => VDD, VSS => VSS,
              Y_drv => Y_drv, Y_cap => Y_cap, VDD_drv => vdd_drv);

  stim : process
  begin
    -- Phase 1: NULL — all inputs 0.
    A <= Z; B <= Z; C <= Z; wait for 10 ns;
    report "after NULL:  Y=" & real'image(Y_drv.voltage);

    -- Phase 2: DATA all-HIGH — (V,V,V).
    A <= HI; B <= HI; C <= HI; wait for 10 ns;
    report "after (V,V,V): Y=" & real'image(Y_drv.voltage);

    -- Phase 3: NULL again.
    A <= Z; B <= Z; C <= Z; wait for 10 ns;
    report "after NULL:  Y=" & real'image(Y_drv.voltage);

    -- Phase 4: DATA with C=0 — (V,V,0) — THIS is the "fire" case we need.
    A <= HI; B <= HI; C <= Z; wait for 10 ns;
    report "after (V,V,0): Y=" & real'image(Y_drv.voltage)
      & "  EXPECT ~1.2 (majority fire)";

    std.env.finish;
  end process;
end architecture;
