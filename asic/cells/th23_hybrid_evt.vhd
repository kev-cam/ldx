-- th23_hybrid_evt.vhd — Event-driven TH23 (majority-of-3) with
-- zone-switched conductances + analytical keeper. IV-table-grade
-- reliability: no NN training residual. Mirrors th22_hybrid_evt
-- topology exactly, just with a 3-input majority fire condition.
--
-- Sub-network conduction rules (from cells/th_gates.sp):
--   Pull-up ON : all three PMOS in series ON ⇔ all three inputs LOW
--   Pull-down ON : at least one of the three 2-stack branches conducts,
--                  i.e. ≥2 of {A,B,C} are HIGH (majority).
--   Keeper: analytical weak inverter with gate=Y, output=X.

library ieee;
use ieee.math_real.all;
use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity th23_hybrid_evt is
  port (
    A       : in  logic3da;
    B       : in  logic3da;
    C       : in  logic3da;
    VDD     : in  logic3da;
    VSS     : in  logic3da;
    Y_drv   : out logic3da;
    Y_cap   : out real;
    VDD_drv : out logic3da
  );
end entity;

architecture evt of th23_hybrid_evt is

  constant VTN     : real := 0.40;
  constant VTP_ABS : real := 0.35;
  constant VDD_NOM : real := 1.20;

  -- Drive resistances from IV tables: R = VDD / I_max. TH23 pull-up is
  -- a 3-PMOS stack (same width as TH22's 2-stack at this sizing, so
  -- ~similar R_PU), pull-down has 3 parallel branches so max current
  -- is ~3× TH22's — R_PD much smaller.
  constant R_PU_ON  : real := 1.95e4;
  constant R_PD_ON  : real := 2.7e3;
  constant R_OFF    : real := 1.0e9;
  constant R_INV    : real := 1.05e4;
  constant R_KEEP   : real := 8.0e4;

  constant C_X : real := 6.4e-15;
  constant C_Y : real := 5.0e-15;

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
    variable za, zb, zc                : integer := 0;
    variable za_new, zb_new, zc_new    : integer;
    variable vdd_v                      : real;
    variable a_lo, b_lo, c_lo           : boolean;
    variable a_hi, b_hi, c_hi           : boolean;
    variable r_pu, r_pd                 : real;
    variable v_x_ss, v_y_ss             : real;
    variable i_supply                   : real;
  begin
    Y_drv <= (voltage => 0.0, resistance => R_INV, flags => AFL_KNOWN);
    Y_cap <= C_Y;
    VDD_drv <= (voltage => 0.0, resistance => R_OFF, flags => AFL_KNOWN);

    loop
    wait on A, B, C, VDD;

    vdd_v := VDD.voltage;
    za_new := zone(A.voltage, vdd_v);
    zb_new := zone(B.voltage, vdd_v);
    zc_new := zone(C.voltage, vdd_v);

    if za_new /= za or zb_new /= zb or zc_new /= zc then
    za := za_new;
    zb := zb_new;
    zc := zc_new;

    a_lo := za = 0; a_hi := za = 2;
    b_lo := zb = 0; b_hi := zb = 2;
    c_lo := zc = 0; c_hi := zc = 2;

    -- Pull-up: all three inputs LOW (all 3 PMOS in series conducting).
    if a_lo and b_lo and c_lo then
      r_pu := R_PU_ON;
    else
      r_pu := R_OFF;
    end if;

    -- Pull-down: majority (≥2 HIGH).
    if (a_hi and b_hi) or (a_hi and c_hi) or (b_hi and c_hi) then
      r_pd := R_PD_ON;
    else
      r_pd := R_OFF;
    end if;

    -- Steady-state V(X): Thevenin combination of pullup, pulldown, keeper.
    v_x_ss := (vdd_v/r_pu + (vdd_v - v_y)/R_KEEP) /
              (1.0/r_pu + 1.0/r_pd + 1.0/R_KEEP);

    if v_x_ss > VTN then
      v_y_ss := 0.0;
    else
      v_y_ss := vdd_v;
    end if;

    -- One feedback iteration to settle keeper.
    v_x_ss := (vdd_v/r_pu + (vdd_v - v_y_ss)/R_KEEP) /
              (1.0/r_pu + 1.0/r_pd + 1.0/R_KEEP);
    if v_x_ss > VTN then
      v_y_ss := 0.0;
    else
      v_y_ss := vdd_v;
    end if;

    v_y <= v_y_ss;

    i_supply := abs(vdd_v - v_x_ss)/r_pu +
                abs(v_x_ss)/r_pd +
                abs(vdd_v - v_y_ss - v_x_ss)/R_KEEP;

    Y_drv <= (voltage => v_y_ss, resistance => R_INV, flags => AFL_KNOWN);
    Y_cap <= C_Y;
    if vdd_v > 0.01 then
      VDD_drv <= (voltage => 0.0,
                  resistance => vdd_v / (i_supply + 1.0e-12),
                  flags => AFL_KNOWN);
    end if;

    end if;
    end loop;
  end process;

end architecture;
