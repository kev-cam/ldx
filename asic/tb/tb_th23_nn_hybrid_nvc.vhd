-- tb_th23_nn_hybrid_nvc.vhd — TH23 (2-of-3 majority) NN-hybrid cell test.
-- Verifies that the analytical keeper + NN drive current topology works
-- for a 3-input gate, not just TH22.
--
-- TH23 semantics (NCL majority-with-hysteresis):
--   Y rises when ≥2 of {A,B,C} are HIGH (majority condition met).
--   Y falls only when all 3 are LOW (strict NCL reset condition).
--   Between those boundaries the keeper holds the previous state.

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_th23_nn_hybrid_nvc is
end entity;

architecture sim of tb_th23_nn_hybrid_nvc is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);

  signal A   : resolved_logic3da := ZERO_L3DA;
  signal B   : resolved_logic3da := ZERO_L3DA;
  signal C   : resolved_logic3da := ZERO_L3DA;
  signal Y   : resolved_logic3da := ZERO_L3DA;
  signal VDD : resolved_logic3da := (voltage => 1.2, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  signal y_drv : logic3da := ZERO_L3DA;
  signal y_cap : real := 0.0;
  signal vdd_drv : logic3da := ZERO_L3DA;
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
    drive(0.0, 0.0, 0.0); wait for 10 ns;  -- 000 → Y=0 (reset)
    drive(1.2, 0.0, 0.0); wait for 10 ns;  -- 100 → Y=0 (1 of 3)
    drive(1.2, 1.2, 0.0); wait for 10 ns;  -- 110 → Y=1 (majority fires)
    drive(1.2, 1.2, 1.2); wait for 10 ns;  -- 111 → Y=1 (stays)
    drive(0.0, 1.2, 1.2); wait for 10 ns;  -- 011 → Y=1 (still majority)
    drive(0.0, 0.0, 1.2); wait for 10 ns;  -- 001 → Y=1 (hold, only 1 of 3)
    drive(0.0, 0.0, 0.0); wait for 10 ns;  -- 000 → Y=0 (reset)
    wait;
  end process;

  dut : entity work.th23_nn_hybrid
    port map (A => A, B => B, C => C,
              VDD => VDD, VSS => VSS,
              Y_drv => y_drv, Y_cap => y_cap, VDD_drv => vdd_drv);

  Y <= y_drv;

  report_proc : process
    type phase_t is record
      a, b, c, expect : real;
      tag : string(1 to 20);
    end record;
    type phase_arr is array (natural range <>) of phase_t;
    constant phases : phase_arr := (
      (0.0, 0.0, 0.0, 0.0, "0 RST 0 (000)       "),
      (1.2, 0.0, 0.0, 0.0, "1 HOLD 0 (100)      "),
      (1.2, 1.2, 0.0, 1.2, "2 SET 1 (110)       "),
      (1.2, 1.2, 1.2, 1.2, "3 STAY 1 (111)      "),
      (0.0, 1.2, 1.2, 1.2, "4 STAY 1 (011)      "),
      (0.0, 0.0, 1.2, 1.2, "5 HOLD 1 (001)      "),
      (0.0, 0.0, 0.0, 0.0, "6 RST 0 (000)       ")
    );
    constant TOL : real := 0.30;
    variable fails : integer := 0;
  begin
    for i in phases'range loop
      wait for 5 ns;
      report "phase " & phases(i).tag &
             " A=" & real'image(phases(i).a) &
             " B=" & real'image(phases(i).b) &
             " C=" & real'image(phases(i).c) &
             " expect=" & real'image(phases(i).expect) &
             " got=" & real'image(Y.voltage);
      if abs(Y.voltage - phases(i).expect) > TOL then
        fails := fails + 1;
      end if;
      wait for 5 ns;
    end loop;
    if fails = 0 then
      report "ALL 7 PHASES within " & real'image(TOL*1000.0) & " mV";
    else
      report integer'image(fails) & " phases out of tolerance"
        severity warning;
    end if;
    std.env.finish;
  end process;
end architecture;
