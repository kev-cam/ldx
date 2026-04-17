-- th22_hybrid_evt.vhd — Event-driven TH22 with rail-departure wake-up.
--
-- Wakes ONLY when an input departs its rail — i.e. when transistors
-- start conducting. Three zones per input:
--   LOW  (< Vtn):        NMOS off, PMOS may be on
--   ACTIVE (Vtn..VDD-Vtp): transistors conducting, edge in progress
--   HIGH (> VDD-Vtp):     NMOS may be on, PMOS off
--
-- The cell re-evaluates when any input's zone changes. Between zone
-- changes, the keeper holds state. This matches NCL protocol where
-- inputs switch cleanly between rails.

library ieee;
use ieee.math_real.all;
use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity th22_hybrid_evt is
  port (
    A       : in  logic3da;
    B       : in  logic3da;
    VDD     : in  logic3da;
    VSS     : in  logic3da;
    Y_drv   : out logic3da;
    Y_cap   : out real;
    VDD_drv : out logic3da
  );
end entity;

architecture evt of th22_hybrid_evt is

  -- Transistor thresholds from SG13G2 PSP103 characterisation.
  -- Pull-down (NMOS) begins conducting at V_gate > Vtn.
  -- Pull-up (PMOS) begins conducting at V_gate < VDD - |Vtp|.
  constant VTN     : real := 0.40;   -- NMOS threshold
  constant VTP_ABS : real := 0.35;   -- |Vtp| PMOS threshold magnitude
  constant VDD_NOM : real := 1.20;

  -- Drive resistances from IV tables (effective R = VDD / I_max).
  constant R_PU_ON  : real := 1.9e4;   -- pull-up strong drive
  constant R_PD_ON  : real := 2.4e4;   -- pull-down strong drive
  constant R_OFF    : real := 1.0e9;
  constant R_INV    : real := 1.05e4;   -- output inverter
  constant R_KEEP   : real := 8.0e4;    -- analytical keeper

  -- Gate caps (next-stage load model).
  constant C_X : real := 6.4e-15;  -- internal: inv + keeper gates
  constant C_Y : real := 5.0e-15;  -- external load (instance param)

  -- Zone encoding: 0=LOW, 1=ACTIVE, 2=HIGH
  function zone(v, vdd : real) return integer is
  begin
    if v < VTN then return 0;
    elsif v > vdd - VTP_ABS then return 2;
    else return 1;
    end if;
  end function;

  signal v_y : real := 0.0;

begin

  eval : process
    variable za, zb           : integer := 0;
    variable za_new, zb_new   : integer;
    variable vdd_v            : real;
    variable a_lo, b_lo       : boolean;
    variable a_hi, b_hi       : boolean;
    variable r_pu, r_pd       : real;
    variable v_x_ss, v_y_ss   : real;
    variable i_supply         : real;
  begin
    -- Initial driver emission (t=0): both inputs at LOW rail, pull-up
    -- dominates, X→VDD, inverter drives Y→0.
    Y_drv <= (voltage => 0.0, resistance => R_INV, flags => AFL_KNOWN);
    Y_cap <= C_Y;
    VDD_drv <= (voltage => 0.0, resistance => R_OFF, flags => AFL_KNOWN);

    loop
    wait on A, B, VDD;

    vdd_v := VDD.voltage;
    za_new := zone(A.voltage, vdd_v);
    zb_new := zone(B.voltage, vdd_v);

    -- Only re-evaluate if a zone changed.
    if za_new /= za or zb_new /= zb then
    za := za_new;
    zb := zb_new;

    a_lo := za = 0;   a_hi := za = 2;
    b_lo := zb = 0;   b_hi := zb = 2;

    -- Pull-up ON when both inputs in LOW zone (both PMOS conducting).
    if a_lo and b_lo then
      r_pu := R_PU_ON;
    else
      r_pu := R_OFF;
    end if;

    -- Pull-down ON when both inputs in HIGH zone (both NMOS conducting).
    if a_hi and b_hi then
      r_pd := R_PD_ON;
    else
      r_pd := R_OFF;
    end if;

    -- Steady-state V(X): Thevenin combination of three drivers.
    --   Pull-up: V=VDD, R=r_pu
    --   Pull-down: V=0, R=r_pd
    --   Keeper: V=(VDD - v_y), R=R_KEEP
    v_x_ss := (vdd_v/r_pu + (vdd_v - v_y)/R_KEEP) /
              (1.0/r_pu + 1.0/r_pd + 1.0/R_KEEP);

    -- Inverter: digital inversion of X.
    if v_x_ss > VTN then
      v_y_ss := 0.0;
    else
      v_y_ss := vdd_v;
    end if;

    -- One more feedback iteration to settle keeper.
    v_x_ss := (vdd_v/r_pu + (vdd_v - v_y_ss)/R_KEEP) /
              (1.0/r_pu + 1.0/r_pd + 1.0/R_KEEP);
    if v_x_ss > VTN then
      v_y_ss := 0.0;
    else
      v_y_ss := vdd_v;
    end if;

    v_y <= v_y_ss;

    -- Supply current at steady state.
    i_supply := abs(vdd_v - v_x_ss)/r_pu +
                abs(v_x_ss)/r_pd +
                abs(vdd_v - v_y_ss - v_x_ss)/R_KEEP;

    -- Emit drivers.
    Y_drv <= (voltage => v_y_ss, resistance => R_INV, flags => AFL_KNOWN);
    Y_cap <= C_Y;
    if vdd_v > 0.01 then
      VDD_drv <= (voltage => 0.0,
                  resistance => vdd_v / (i_supply + 1.0e-12),
                  flags => AFL_KNOWN);
    end if;

    end if; -- zone changed guard
    end loop;
  end process;

end architecture;
