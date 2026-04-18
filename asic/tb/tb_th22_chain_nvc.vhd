-- tb_th22_chain_nvc.vhd — Two-stage TH22 NN-hybrid chain.
--
-- Tests cell-to-cell composition through NVC's logic3da resolver. Stage 1
-- is TH22(A, B) → mid; stage 2 is TH22(mid, C) → Y. This exercises the
-- driver/resolver path between cells (stage 1's Y_drv feeds stage 2's
-- input via a resolved net), which the single-cell testbench can't.
--
-- Logical expectation: both TH22s are C-elements, so Y only rises when
-- all of (A, B, C) are HIGH and holds until all are LOW. Stage 1 is a
-- TH22 of (A, B) (must both be HIGH for mid to fire), stage 2 gates
-- on (mid, C). Net result is TH22 of the AND, i.e. TH-all-three.

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_th22_chain_nvc is
end entity;

architecture sim of tb_th22_chain_nvc is

  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);

  signal A   : resolved_logic3da := ZERO_L3DA;
  signal B   : resolved_logic3da := ZERO_L3DA;
  signal C   : resolved_logic3da := ZERO_L3DA;
  signal MID : resolved_logic3da := ZERO_L3DA;
  signal Y   : resolved_logic3da := ZERO_L3DA;
  signal VDD : resolved_logic3da := (voltage => 1.2, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  -- Stage 1 driver outputs
  signal mid_drv : logic3da := ZERO_L3DA;
  signal mid_cap : real := 0.0;
  signal vdd1    : logic3da := ZERO_L3DA;

  -- Stage 2 driver outputs
  signal y_drv   : logic3da := ZERO_L3DA;
  signal y_cap   : real := 0.0;
  signal vdd2    : logic3da := ZERO_L3DA;

begin

  VDD <= (voltage => 1.2, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= (voltage => 0.0, resistance => 0.0, flags => AFL_KNOWN);

  stim : process
    procedure drive(av, bv, cv : real) is
    begin
      A <= (voltage => av, resistance => 0.0, flags => AFL_KNOWN);
      B <= (voltage => bv, resistance => 0.0, flags => AFL_KNOWN);
      C <= (voltage => cv, resistance => 0.0, flags => AFL_KNOWN);
    end procedure;
  begin
    -- 8 test cases — walk (A,B,C) through all 3-bit patterns with
    -- enough dwell time for the RC of the two-stage chain to settle.
    drive(0.0, 0.0, 0.0); wait for 20 ns;  -- phase 0: all low  → Y=0
    drive(1.2, 0.0, 0.0); wait for 20 ns;  -- phase 1: 100      → Y=0 (mid didn't fire)
    drive(1.2, 1.2, 0.0); wait for 20 ns;  -- phase 2: 110      → mid=1 but stage2 C=0, Y=0
    drive(1.2, 1.2, 1.2); wait for 20 ns;  -- phase 3: 111      → Y=1
    drive(0.0, 1.2, 1.2); wait for 20 ns;  -- phase 4: 011 hold → Y stays 1
    drive(0.0, 0.0, 1.2); wait for 20 ns;  -- phase 5: 001 hold → Y stays 1
    drive(0.0, 0.0, 0.0); wait for 20 ns;  -- phase 6: all low  → Y=0
    drive(1.2, 1.2, 1.2); wait for 20 ns;  -- phase 7: all high → Y=1
    wait;
  end process;

  -- Stage 1: TH22(A, B) → MID
  u1 : entity work.th22_nn_hybrid
    port map (A => A, B => B, VDD => VDD, VSS => VSS,
              Y_drv => mid_drv, Y_cap => mid_cap, VDD_drv => vdd1);

  -- Stage 2: TH22(MID, C) → Y
  u2 : entity work.th22_nn_hybrid
    port map (A => MID, B => C, VDD => VDD, VSS => VSS,
              Y_drv => y_drv, Y_cap => y_cap, VDD_drv => vdd2);

  -- Resolve the inter-cell net (stage1 drives MID) and the output net.
  MID <= mid_drv;
  Y   <= y_drv;

  report_proc : process
    type phase_t is record
      a, b, c, expect : real;
      tag : string(1 to 20);
    end record;
    type phase_arr is array (natural range <>) of phase_t;
    constant phases : phase_arr := (
      (0.0, 0.0, 0.0, 0.0, "0 SET 0 (000)       "),
      (1.2, 0.0, 0.0, 0.0, "1 HOLD 0 (100)      "),
      (1.2, 1.2, 0.0, 0.0, "2 HOLD 0 (110,mid=1)"),
      (1.2, 1.2, 1.2, 1.2, "3 SET 1 (111)       "),
      (0.0, 1.2, 1.2, 1.2, "4 HOLD 1 (011)      "),
      (0.0, 0.0, 1.2, 1.2, "5 HOLD 1 (001)      "),
      (0.0, 0.0, 0.0, 0.0, "6 SET 0 (000)       "),
      (1.2, 1.2, 1.2, 1.2, "7 SET 1 (111)       ")
    );
    constant TOL : real := 0.30;
    variable fails : integer := 0;
  begin
    for i in phases'range loop
      -- Sample at 15 ns into each 20 ns phase.
      wait for 15 ns;
      report "phase " & phases(i).tag &
             "  A=" & real'image(phases(i).a) &
             "  B=" & real'image(phases(i).b) &
             "  C=" & real'image(phases(i).c) &
             "  expect=" & real'image(phases(i).expect) &
             "  got=" & real'image(Y.voltage);
      if abs(Y.voltage - phases(i).expect) > TOL then
        fails := fails + 1;
      end if;
      wait for 5 ns;
    end loop;
    if fails = 0 then
      report "ALL " & integer'image(phases'length)
             & " PHASES within " & real'image(TOL*1000.0) & " mV";
    else
      report integer'image(fails) & " phases out of tolerance"
        severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
