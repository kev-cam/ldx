-- tb_nclfa_nn_hybrid_nvc.vhd — Structural NCL 1-bit full adder from
-- NN-hybrid cells. Proves the cells compose into a real NCL arithmetic
-- unit through NVC's logic3da resolver.
--
-- Topology (from cells/nclfa.sp, Fant canonical form):
--   coH = TH23(aH, bH, ciH)
--   coL = TH23(aL, bL, ciL)
--   sH  = TH34W2(coL, aH, bH, ciH)      -- weight-2 input is the first
--   sL  = TH34W2(coH, aL, bL, ciL)
--
-- Dual-rail encoding: (H,L) = (1,0) → '1', (H,L) = (0,1) → '0', (0,0)
-- → NULL. We run the 8-case full-adder truth table between NULL windows.

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_nclfa_nn_hybrid_nvc is
end entity;

architecture sim of tb_nclfa_nn_hybrid_nvc is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);
  constant VDD_V : real := 1.2;

  -- Dual-rail I/O nets (all resolved_logic3da).
  signal aH, aL   : resolved_logic3da := ZERO_L3DA;
  signal bH, bL   : resolved_logic3da := ZERO_L3DA;
  signal ciH, ciL : resolved_logic3da := ZERO_L3DA;
  signal sH, sL   : resolved_logic3da := ZERO_L3DA;
  signal coH, coL : resolved_logic3da := ZERO_L3DA;

  signal VDD : resolved_logic3da := (voltage => VDD_V, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  -- Per-cell driver signals (each cell emits its own).
  signal coH_drv, coL_drv : logic3da := ZERO_L3DA;
  signal sH_drv , sL_drv  : logic3da := ZERO_L3DA;
  signal coH_cap, coL_cap : real := 0.0;
  signal sH_cap , sL_cap  : real := 0.0;
  signal vddX1, vddX2, vddX3, vddX4 : logic3da := ZERO_L3DA;
begin

  VDD <= (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= (voltage => 0.0, resistance => 0.0, flags => AFL_KNOWN);

  -- 4-phase NCL stimulus: drive NULL → DATA → NULL → DATA for each
  -- truth-table case, giving the pipeline time to settle between cases.
  stim : process
    procedure drive(va_h, va_l, vb_h, vb_l, vci_h, vci_l : real) is
    begin
      aH  <= (voltage => va_h,  resistance => 0.0, flags => AFL_KNOWN);
      aL  <= (voltage => va_l,  resistance => 0.0, flags => AFL_KNOWN);
      bH  <= (voltage => vb_h,  resistance => 0.0, flags => AFL_KNOWN);
      bL  <= (voltage => vb_l,  resistance => 0.0, flags => AFL_KNOWN);
      ciH <= (voltage => vci_h, resistance => 0.0, flags => AFL_KNOWN);
      ciL <= (voltage => vci_l, resistance => 0.0, flags => AFL_KNOWN);
    end procedure;

    procedure nullify is
    begin
      drive(0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    end procedure;

    -- Dual-rail: H=1.2 L=0 encodes '1'; H=0 L=1.2 encodes '0'.
    procedure set_case (a, b, c : integer) is
      variable vah, val, vbh, vbl, vcih, vcil : real;
    begin
      if a = 1 then vah := VDD_V; val := 0.0;
      else          vah := 0.0;   val := VDD_V;
      end if;
      if b = 1 then vbh := VDD_V; vbl := 0.0;
      else          vbh := 0.0;   vbl := VDD_V;
      end if;
      if c = 1 then vcih := VDD_V; vcil := 0.0;
      else          vcih := 0.0;   vcil := VDD_V;
      end if;
      drive(vah, val, vbh, vbl, vcih, vcil);
    end procedure;

  begin
    nullify;       wait for 10 ns;
    set_case(0,0,0); wait for 20 ns;  -- sum=0, cout=0
    nullify;       wait for 10 ns;
    set_case(0,0,1); wait for 20 ns;  -- sum=1, cout=0
    nullify;       wait for 10 ns;
    set_case(0,1,0); wait for 20 ns;  -- sum=1, cout=0
    nullify;       wait for 10 ns;
    set_case(0,1,1); wait for 20 ns;  -- sum=0, cout=1
    nullify;       wait for 10 ns;
    set_case(1,0,0); wait for 20 ns;  -- sum=1, cout=0
    nullify;       wait for 10 ns;
    set_case(1,0,1); wait for 20 ns;  -- sum=0, cout=1
    nullify;       wait for 10 ns;
    set_case(1,1,0); wait for 20 ns;  -- sum=0, cout=1
    nullify;       wait for 10 ns;
    set_case(1,1,1); wait for 20 ns;  -- sum=1, cout=1
    nullify;       wait for 10 ns;
    wait;
  end process;

  -- ---- DUT: NCL 1-bit full adder from cells/nclfa.sp ----
  u_coh : entity work.th23_nn_hybrid
    port map (A => aH, B => bH, C => ciH,
              VDD => VDD, VSS => VSS,
              Y_drv => coH_drv, Y_cap => coH_cap, VDD_drv => vddX1);

  u_col : entity work.th23_nn_hybrid
    port map (A => aL, B => bL, C => ciL,
              VDD => VDD, VSS => VSS,
              Y_drv => coL_drv, Y_cap => coL_cap, VDD_drv => vddX2);

  coH <= coH_drv;
  coL <= coL_drv;

  u_sh : entity work.th34w2_nn_hybrid
    port map (A => coL, B => aH, C => bH, D => ciH,
              VDD => VDD, VSS => VSS,
              Y_drv => sH_drv, Y_cap => sH_cap, VDD_drv => vddX3);

  u_sl : entity work.th34w2_nn_hybrid
    port map (A => coH, B => aL, C => bL, D => ciL,
              VDD => VDD, VSS => VSS,
              Y_drv => sL_drv, Y_cap => sL_cap, VDD_drv => vddX4);

  sH <= sH_drv;
  sL <= sL_drv;

  -- ---- Report process: sample output during DATA windows ----
  report_proc : process
    type c_t is record
      a, b, c, sum, cout : integer;
    end record;
    type c_arr is array (natural range <>) of c_t;
    constant cases : c_arr := (
      (0,0,0, 0,0),
      (0,0,1, 1,0),
      (0,1,0, 1,0),
      (0,1,1, 0,1),
      (1,0,0, 1,0),
      (1,0,1, 0,1),
      (1,1,0, 0,1),
      (1,1,1, 1,1)
    );
    constant TOL : real := 0.30;
    variable fails : integer := 0;

    function dec(H, L : real) return integer is
    begin
      -- Decode dual rail to bit. HIGH-rail at VDD and LOW-rail at 0 → '1'.
      if    H > VDD_V/2.0 and L < VDD_V/2.0 then return 1;
      elsif H < VDD_V/2.0 and L > VDD_V/2.0 then return 0;
      else  return -1;  -- undefined / NULL
      end if;
    end function;

  begin
    -- Line up to middle of first DATA window (10 ns NULL + 15 ns into DATA).
    wait for 25 ns;
    for i in cases'range loop
      report "case a=" & integer'image(cases(i).a) &
             " b=" & integer'image(cases(i).b) &
             " cin=" & integer'image(cases(i).c) &
             "  sum(H,L)=(" & real'image(sH.voltage) & "," & real'image(sL.voltage) &
             ") cout(H,L)=(" & real'image(coH.voltage) & "," & real'image(coL.voltage) &
             ")  expect sum=" & integer'image(cases(i).sum) &
             " cout=" & integer'image(cases(i).cout);
      if dec(sH.voltage, sL.voltage)   /= cases(i).sum  then fails := fails + 1; end if;
      if dec(coH.voltage, coL.voltage) /= cases(i).cout then fails := fails + 1; end if;
      wait for 30 ns;   -- advance to next (DATA + NULL + into next DATA)
    end loop;

    if fails = 0 then
      report "ALL 8 FA CASES correct";
    else
      report integer'image(fails) & " decode failures"
        severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
