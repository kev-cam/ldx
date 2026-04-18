-- tb_ncl_add4_nn_assert.vhd — 4-bit async NCL ripple adder with
-- the same assertion/correction harness as the 2-bit version.
-- Uses hysteresis-aware NCL reference (th23_ncl / th34w2_ncl) and
-- injects corrected carry values between bits so each cell's error
-- is localised to its own output.

library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

use work.ncl.all;

entity tb_ncl_add4_nn_assert is
end entity;

architecture sim of tb_ncl_add4_nn_assert is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);
  constant VDD_V : real := 1.2;

  -- Dual-rail inputs, 4 bits (discrete signals — avoids VHDL's
  -- "non-static signal name" quirks when assigning aH(i) via procedure).
  signal aH0, aL0, bH0, bL0 : resolved_logic3da := ZERO_L3DA;
  signal aH1, aL1, bH1, bL1 : resolved_logic3da := ZERO_L3DA;
  signal aH2, aL2, bH2, bL2 : resolved_logic3da := ZERO_L3DA;
  signal aH3, aL3, bH3, bL3 : resolved_logic3da := ZERO_L3DA;
  signal cinH, cinL : resolved_logic3da := ZERO_L3DA;

  -- Raw cell outputs (one per FA instance).
  signal coH0_raw, coL0_raw, sH0_raw, sL0_raw : logic3da := ZERO_L3DA;
  signal coH1_raw, coL1_raw, sH1_raw, sL1_raw : logic3da := ZERO_L3DA;
  signal coH2_raw, coL2_raw, sH2_raw, sL2_raw : logic3da := ZERO_L3DA;
  signal coH3_raw, coL3_raw, sH3_raw, sL3_raw : logic3da := ZERO_L3DA;

  -- Corrected carry chain.
  signal ciH1, ciL1, ciH2, ciL2, ciH3, ciL3 : resolved_logic3da := ZERO_L3DA;

  signal VDD : resolved_logic3da := (voltage => VDD_V, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  -- Stubs.
  signal sh0c, sl0c, coh0c, col0c : real := 0.0;
  signal sh1c, sl1c, coh1c, col1c : real := 0.0;
  signal sh2c, sl2c, coh2c, col2c : real := 0.0;
  signal sh3c, sl3c, coh3c, col3c : real := 0.0;
  signal v0a, v0b, v0c, v0d : logic3da := ZERO_L3DA;
  signal v1a, v1b, v1c, v1d : logic3da := ZERO_L3DA;
  signal v2a, v2b, v2c, v2d : logic3da := ZERO_L3DA;
  signal v3a, v3b, v3c, v3d : logic3da := ZERO_L3DA;

  -- Test input and phase.
  signal test_a, test_b, test_ci : integer := 0;
  signal data_phase : boolean := false;

  -- Reference signals, hysteresis-aware NCL state.
  signal ref_coH0, ref_coL0, ref_sH0, ref_sL0 : std_logic := '0';
  signal ref_coH1, ref_coL1, ref_sH1, ref_sL1 : std_logic := '0';
  signal ref_coH2, ref_coL2, ref_sH2, ref_sL2 : std_logic := '0';
  signal ref_coH3, ref_coL3, ref_sH3, ref_sL3 : std_logic := '0';

  function to_rail (b : integer) return std_logic is
  begin
    if b = 1 then return '1'; else return '0'; end if;
  end function;

  function th23_ncl (a, b, c, prev : std_logic) return std_logic is
  begin
    if (a='1' and b='1') or (a='1' and c='1') or (b='1' and c='1') then
      return '1';
    elsif a='0' and b='0' and c='0' then return '0';
    else return prev;
    end if;
  end function;

  function th34w2_ncl (a, b, c, d, prev : std_logic) return std_logic is
  begin
    if (a='1' and b='1') or (a='1' and c='1') or (a='1' and d='1')
       or (b='1' and c='1' and d='1') then return '1';
    elsif a='0' and b='0' and c='0' and d='0' then return '0';
    else return prev;
    end if;
  end function;

  function rail_ok (v : real; expect : std_logic) return boolean is
  begin
    if expect = '1' then return v > VDD_V * 0.5;
    else               return v < VDD_V * 0.5;
    end if;
  end function;

  function corrected (raw : logic3da; ref : std_logic; active : boolean)
    return logic3da is
  begin
    if not active then return raw; end if;
    if rail_ok(raw.voltage, ref) then return raw; end if;
    if ref = '1' then
      return (voltage => VDD_V, resistance => 1.0e3, flags => AFL_KNOWN);
    else
      return (voltage => 0.0,   resistance => 1.0e3, flags => AFL_KNOWN);
    end if;
  end function;

begin

  VDD <= (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= ZERO_L3DA;

  -- ---- Reference computation (hysteresis-aware) ----
  ref_proc : process (test_a, test_b, test_ci, data_phase)
    variable ahb, alb, bhb, blb : std_logic_vector(3 downto 0);
    variable ciHb, ciLb : std_logic;
    variable cih : std_logic_vector(4 downto 0);
    variable cil : std_logic_vector(4 downto 0);
  begin
    if not data_phase then
      ref_coH0 <= '0'; ref_coL0 <= '0'; ref_sH0 <= '0'; ref_sL0 <= '0';
      ref_coH1 <= '0'; ref_coL1 <= '0'; ref_sH1 <= '0'; ref_sL1 <= '0';
      ref_coH2 <= '0'; ref_coL2 <= '0'; ref_sH2 <= '0'; ref_sL2 <= '0';
      ref_coH3 <= '0'; ref_coL3 <= '0'; ref_sH3 <= '0'; ref_sL3 <= '0';
    else
      for i in 0 to 3 loop
        ahb(i) := to_rail((test_a / (2**i)) mod 2);
        alb(i) := to_rail(1 - ((test_a / (2**i)) mod 2));
        bhb(i) := to_rail((test_b / (2**i)) mod 2);
        blb(i) := to_rail(1 - ((test_b / (2**i)) mod 2));
      end loop;
      ciHb := to_rail(test_ci);
      ciLb := to_rail(1 - test_ci);

      cih(0) := ciHb; cil(0) := ciLb;

      -- Bit 0
      cih(1) := th23_ncl(ahb(0), bhb(0), cih(0), ref_coH0);
      cil(1) := th23_ncl(alb(0), blb(0), cil(0), ref_coL0);
      ref_coH0 <= cih(1);
      ref_coL0 <= cil(1);
      ref_sH0  <= th34w2_ncl(cil(1), ahb(0), bhb(0), cih(0), ref_sH0);
      ref_sL0  <= th34w2_ncl(cih(1), alb(0), blb(0), cil(0), ref_sL0);

      -- Bit 1
      cih(2) := th23_ncl(ahb(1), bhb(1), cih(1), ref_coH1);
      cil(2) := th23_ncl(alb(1), blb(1), cil(1), ref_coL1);
      ref_coH1 <= cih(2);
      ref_coL1 <= cil(2);
      ref_sH1  <= th34w2_ncl(cil(2), ahb(1), bhb(1), cih(1), ref_sH1);
      ref_sL1  <= th34w2_ncl(cih(2), alb(1), blb(1), cil(1), ref_sL1);

      -- Bit 2
      cih(3) := th23_ncl(ahb(2), bhb(2), cih(2), ref_coH2);
      cil(3) := th23_ncl(alb(2), blb(2), cil(2), ref_coL2);
      ref_coH2 <= cih(3);
      ref_coL2 <= cil(3);
      ref_sH2  <= th34w2_ncl(cil(3), ahb(2), bhb(2), cih(2), ref_sH2);
      ref_sL2  <= th34w2_ncl(cih(3), alb(2), blb(2), cil(2), ref_sL2);

      -- Bit 3
      cih(4) := th23_ncl(ahb(3), bhb(3), cih(3), ref_coH3);
      cil(4) := th23_ncl(alb(3), blb(3), cil(3), ref_coL3);
      ref_coH3 <= cih(4);
      ref_coL3 <= cil(4);
      ref_sH3  <= th34w2_ncl(cil(4), ahb(3), bhb(3), cih(3), ref_sH3);
      ref_sL3  <= th34w2_ncl(cih(4), alb(3), blb(3), cil(3), ref_sL3);
    end if;
  end process;

  -- ---- DUT: 4 FAs with corrected carries ----
  fa0 : entity work.nclfa_nn_hybrid
    port map (aH=>aH0, aL=>aL0, bH=>bH0, bL=>bL0, ciH=>cinH, ciL=>cinL,
              VDD=>VDD, VSS=>VSS,
              sH_drv=>sH0_raw, sH_cap=>sh0c, sL_drv=>sL0_raw, sL_cap=>sl0c,
              coH_drv=>coH0_raw, coH_cap=>coh0c, coL_drv=>coL0_raw, coL_cap=>col0c,
              vdd_drv_coh=>v0a, vdd_drv_col=>v0b, vdd_drv_sh=>v0c, vdd_drv_sl=>v0d);

  ciH1 <= corrected(coH0_raw, ref_coH0, data_phase);
  ciL1 <= corrected(coL0_raw, ref_coL0, data_phase);

  fa1 : entity work.nclfa_nn_hybrid
    port map (aH=>aH1, aL=>aL1, bH=>bH1, bL=>bL1, ciH=>ciH1, ciL=>ciL1,
              VDD=>VDD, VSS=>VSS,
              sH_drv=>sH1_raw, sH_cap=>sh1c, sL_drv=>sL1_raw, sL_cap=>sl1c,
              coH_drv=>coH1_raw, coH_cap=>coh1c, coL_drv=>coL1_raw, coL_cap=>col1c,
              vdd_drv_coh=>v1a, vdd_drv_col=>v1b, vdd_drv_sh=>v1c, vdd_drv_sl=>v1d);

  ciH2 <= corrected(coH1_raw, ref_coH1, data_phase);
  ciL2 <= corrected(coL1_raw, ref_coL1, data_phase);

  fa2 : entity work.nclfa_nn_hybrid
    port map (aH=>aH2, aL=>aL2, bH=>bH2, bL=>bL2, ciH=>ciH2, ciL=>ciL2,
              VDD=>VDD, VSS=>VSS,
              sH_drv=>sH2_raw, sH_cap=>sh2c, sL_drv=>sL2_raw, sL_cap=>sl2c,
              coH_drv=>coH2_raw, coH_cap=>coh2c, coL_drv=>coL2_raw, coL_cap=>col2c,
              vdd_drv_coh=>v2a, vdd_drv_col=>v2b, vdd_drv_sh=>v2c, vdd_drv_sl=>v2d);

  ciH3 <= corrected(coH2_raw, ref_coH2, data_phase);
  ciL3 <= corrected(coL2_raw, ref_coL2, data_phase);

  fa3 : entity work.nclfa_nn_hybrid
    port map (aH=>aH3, aL=>aL3, bH=>bH3, bL=>bL3, ciH=>ciH3, ciL=>ciL3,
              VDD=>VDD, VSS=>VSS,
              sH_drv=>sH3_raw, sH_cap=>sh3c, sL_drv=>sL3_raw, sL_cap=>sl3c,
              coH_drv=>coH3_raw, coH_cap=>coh3c, coL_drv=>coL3_raw, coL_cap=>col3c,
              vdd_drv_coh=>v3a, vdd_drv_col=>v3b, vdd_drv_sh=>v3c, vdd_drv_sl=>v3d);

  -- ---- Stim + checker ----
  stim_check : process
    constant HI : logic3da := (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
    constant LO : logic3da := (voltage => 0.0,   resistance => 0.0, flags => AFL_KNOWN);
    type c_t is record
      a, b, ci, sum, cout : integer;
    end record;
    type c_arr is array (natural range <>) of c_t;
    constant cases : c_arr := (
      (0,  0, 0,  0, 0),
      (1,  1, 0,  2, 0),
      (3,  4, 0,  7, 0),
      (7,  8, 0, 15, 0),
      (15, 1, 0,  0, 1),
      (9,  5, 1, 15, 0),
      (15,15, 1, 15, 1)
    );
    variable mismatches : integer := 0;

    procedure nullify_in is
    begin
      data_phase <= false;
      aH0<=ZERO_L3DA; aL0<=ZERO_L3DA; bH0<=ZERO_L3DA; bL0<=ZERO_L3DA;
      aH1<=ZERO_L3DA; aL1<=ZERO_L3DA; bH1<=ZERO_L3DA; bL1<=ZERO_L3DA;
      aH2<=ZERO_L3DA; aL2<=ZERO_L3DA; bH2<=ZERO_L3DA; bL2<=ZERO_L3DA;
      aH3<=ZERO_L3DA; aL3<=ZERO_L3DA; bH3<=ZERO_L3DA; bL3<=ZERO_L3DA;
      cinH<=ZERO_L3DA; cinL<=ZERO_L3DA;
    end procedure;

    procedure drive_rail (signal h, l : out resolved_logic3da; bitv : integer) is
    begin
      if bitv = 1 then h<=HI; l<=LO; else h<=LO; l<=HI; end if;
    end procedure;

    procedure apply (av, bv, ci : integer) is
    begin
      test_a <= av; test_b <= bv; test_ci <= ci;
      data_phase <= true;
      if ((av/1) mod 2) = 1 then aH0<=HI; aL0<=LO; else aH0<=LO; aL0<=HI; end if;
      if ((av/2) mod 2) = 1 then aH1<=HI; aL1<=LO; else aH1<=LO; aL1<=HI; end if;
      if ((av/4) mod 2) = 1 then aH2<=HI; aL2<=LO; else aH2<=LO; aL2<=HI; end if;
      if ((av/8) mod 2) = 1 then aH3<=HI; aL3<=LO; else aH3<=LO; aL3<=HI; end if;
      if ((bv/1) mod 2) = 1 then bH0<=HI; bL0<=LO; else bH0<=LO; bL0<=HI; end if;
      if ((bv/2) mod 2) = 1 then bH1<=HI; bL1<=LO; else bH1<=LO; bL1<=HI; end if;
      if ((bv/4) mod 2) = 1 then bH2<=HI; bL2<=LO; else bH2<=LO; bL2<=HI; end if;
      if ((bv/8) mod 2) = 1 then bH3<=HI; bL3<=LO; else bH3<=LO; bL3<=HI; end if;
      if ci = 1 then cinH<=HI; cinL<=LO; else cinH<=LO; cinL<=HI; end if;
    end procedure;

    procedure check (name : string; raw_v : real; ref : std_logic) is
    begin
      if not rail_ok(raw_v, ref) then
        mismatches := mismatches + 1;
        report "  MISMATCH " & name & ": got=" & real'image(raw_v)
             & " expect=" & std_logic'image(ref) severity warning;
      end if;
    end procedure;

    variable got_s, got_c, bv : integer;
  begin
    for i in cases'range loop
      nullify_in;
      wait for 30 ns;
      apply(cases(i).a, cases(i).b, cases(i).ci);
      wait for 60 ns;

      got_s := 0;
      if sH0_raw.voltage > VDD_V/2.0 then got_s := got_s + 1; end if;
      if sH1_raw.voltage > VDD_V/2.0 then got_s := got_s + 2; end if;
      if sH2_raw.voltage > VDD_V/2.0 then got_s := got_s + 4; end if;
      if sH3_raw.voltage > VDD_V/2.0 then got_s := got_s + 8; end if;
      got_c := 0;
      if coH3_raw.voltage > VDD_V/2.0 then got_c := 1; end if;

      report "case " & integer'image(cases(i).a) & " + "
           & integer'image(cases(i).b) & " + "
           & integer'image(cases(i).ci)
           & "  expect sum=" & integer'image(cases(i).sum)
           & " cout=" & integer'image(cases(i).cout)
           & "  got sum=" & integer'image(got_s)
           & " cout=" & integer'image(got_c);

      check("bit0 coH", coH0_raw.voltage, ref_coH0);
      check("bit0 coL", coL0_raw.voltage, ref_coL0);
      check("bit0 sH",  sH0_raw.voltage,  ref_sH0);
      check("bit0 sL",  sL0_raw.voltage,  ref_sL0);
      check("bit1 coH", coH1_raw.voltage, ref_coH1);
      check("bit1 coL", coL1_raw.voltage, ref_coL1);
      check("bit1 sH",  sH1_raw.voltage,  ref_sH1);
      check("bit1 sL",  sL1_raw.voltage,  ref_sL1);
      check("bit2 coH", coH2_raw.voltage, ref_coH2);
      check("bit2 coL", coL2_raw.voltage, ref_coL2);
      check("bit2 sH",  sH2_raw.voltage,  ref_sH2);
      check("bit2 sL",  sL2_raw.voltage,  ref_sL2);
      check("bit3 coH", coH3_raw.voltage, ref_coH3);
      check("bit3 coL", coL3_raw.voltage, ref_coL3);
      check("bit3 sH",  sH3_raw.voltage,  ref_sH3);
      check("bit3 sL",  sL3_raw.voltage,  ref_sL3);
    end loop;
    if mismatches = 0 then
      report "ALL 7 cases clean, 112 per-cell checks matched";
    else
      report integer'image(mismatches) & " cell-level mismatches"
        severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
