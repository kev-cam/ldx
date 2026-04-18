-- tb_th22_nn_hybrid_nvc.vhd — NVC testbench exercising the NN-extracted TH22 cell
-- using NVC's built-in logic3da Thevenin resolution (sv2vhdl/logic3da_pkg).
-- Same 7-phase 4-phase-NCL stimulus as tb_th22.sp so results compare
-- directly to the transistor-level ground truth.

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_th22_nn_hybrid_nvc is
end entity;

architecture sim of tb_th22_nn_hybrid_nvc is

  -- A safe initial value for a known-zero net.
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);

  -- Input nets — resolved logic3da, initialised so the NN sees zero on t=0.
  signal A   : resolved_logic3da := ZERO_L3DA;
  signal B   : resolved_logic3da := ZERO_L3DA;
  signal VDD : resolved_logic3da := (voltage => 1.2, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;
  signal Y   : resolved_logic3da := ZERO_L3DA;

  -- Driver signals from DUT
  signal y_drv : logic3da := ZERO_L3DA;
  signal y_cap : real := 0.0;
  signal vdd_drv : logic3da := ZERO_L3DA;

begin

  -- Supply sources — ideal (R_SUPPLY = 0) voltage sources.
  VDD <= (voltage => 1.2, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= (voltage => 0.0, resistance => 0.0, flags => AFL_KNOWN);

  -- Input stimulus — drive each input as an ideal Thevenin source (R=0).
  stim : process
    procedure drive(a_val, b_val : real) is
    begin
      A <= (voltage => a_val, resistance => 0.0, flags => AFL_KNOWN);
      B <= (voltage => b_val, resistance => 0.0, flags => AFL_KNOWN);
    end procedure;
  begin
    drive(0.0, 0.0); wait for 10 ns;
    drive(1.2, 0.0); wait for 10 ns;
    drive(0.0, 0.0); wait for 10 ns;
    drive(1.2, 1.2); wait for 10 ns;
    drive(0.0, 1.2); wait for 10 ns;
    drive(1.2, 1.2); wait for 10 ns;
    drive(0.0, 0.0); wait for 10 ns;
    wait;
  end process;

  -- DUT
  dut : entity work.th22_nn_hybrid
    port map (A => A, B => B, VDD => VDD, VSS => VSS,
              Y_drv => y_drv, Y_cap => y_cap, VDD_drv => vdd_drv);

  -- Connect driver to the resolved output net
  Y <= y_drv;

  -- Sample + report at 5 ns into each phase
  report_proc : process
    type phase_t is record
      a, b, expect : real;
      txt          : string(1 to 16);
    end record;
    type phase_arr is array (natural range <>) of phase_t;
    constant phases : phase_arr := (
      (0.0, 0.0, 0.0, "phase 0 SET 0   "),
      (1.2, 0.0, 0.0, "phase 1 HOLD 0  "),
      (0.0, 0.0, 0.0, "phase 2 STAY 0  "),
      (1.2, 1.2, 1.2, "phase 3 SET 1   "),
      (0.0, 1.2, 1.2, "phase 4 HOLD 1  "),
      (1.2, 1.2, 1.2, "phase 5 STAY 1  "),
      (0.0, 0.0, 0.0, "phase 6 SET 0   ")
    );
    variable nerr : integer := 0;
    variable diff : real;
  begin
    wait for 5 ns;
    for k in phases'range loop
      report phases(k).txt &
             " A=" & real'image(phases(k).a) &
             " B=" & real'image(phases(k).b) &
             " expect=" & real'image(phases(k).expect) &
             " got=" & real'image(Y.voltage);
      diff := Y.voltage - phases(k).expect;
      if diff < -0.3 or diff > 0.3 then
        nerr := nerr + 1;
      end if;
      wait for 10 ns;
    end loop;
    if nerr = 0 then
      report "ALL 7 PHASES within 300 mV of expected";
    else
      report integer'image(nerr) & " phases out of tolerance" severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
