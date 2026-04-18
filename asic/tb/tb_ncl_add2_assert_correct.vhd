-- tb_ncl_add2_assert_correct.vhd — 2-bit async NCL adder with
-- assertion/correction harness.
--
-- Each cell output (coH, coL, sH, sL × 4 bits × 2 FA stages = 16
-- signals) is compared against the first-principles reference from
-- the sync model. On mismatch, inject the correct value onto the
-- DOWNSTREAM net so the next stage sees correct input. That way
-- the failure localises to exactly the cell whose output first
-- diverges — no cascade.
--
-- The reference `ref_*` signals are computed combinationally from
-- the input stimulus using the sync ncl_sync library's Boolean
-- th23/th34w2 functions — identical to the functions whose behaviour
-- the async cells approximate with hysteresis.

library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

-- Bring in the sync NCL library for the reference Boolean ops.
-- (Note: requires the ncl_sync package compiled into 'work' — tb build
-- analyses it alongside the async cells.)
use work.ncl.all;

entity tb_ncl_add2_assert_correct is
end entity;

architecture sim of tb_ncl_add2_assert_correct is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);
  constant VDD_V : real := 1.2;

  -- Dual-rail inputs, 2 bits.
  signal aH0, aL0, bH0, bL0 : resolved_logic3da := ZERO_L3DA;
  signal aH1, aL1, bH1, bL1 : resolved_logic3da := ZERO_L3DA;
  signal cinH, cinL : resolved_logic3da := ZERO_L3DA;

  -- Carry / sum outputs — raw from cells and corrected versions.
  signal coH0_raw, coL0_raw, sH0_raw, sL0_raw : logic3da := ZERO_L3DA;
  signal coH1_raw, coL1_raw, sH1_raw, sL1_raw : logic3da := ZERO_L3DA;

  -- Corrected carry nets feeding bit 1.
  signal ciH1_corrected, ciL1_corrected : resolved_logic3da := ZERO_L3DA;

  signal VDD : resolved_logic3da := (voltage => VDD_V, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  -- Stubs for cells' unused outputs.
  signal sH0_cap, sL0_cap, coH0_cap, coL0_cap : real := 0.0;
  signal sH1_cap, sL1_cap, coH1_cap, coL1_cap : real := 0.0;
  signal vdd0_coh, vdd0_col, vdd0_sh, vdd0_sl : logic3da := ZERO_L3DA;
  signal vdd1_coh, vdd1_col, vdd1_sh, vdd1_sl : logic3da := ZERO_L3DA;

  -- Test input: a, b, cin.
  signal test_a, test_b, test_ci : integer := 0;
  -- DATA-phase gate: when false (during NULL) correction is disabled.
  signal data_phase : boolean := false;

  -- Expected per-bit reference values (std_logic), NCL-hysteresis-aware.
  -- Start at '0' — matches the post-reset state of each cell at t=0.
  signal ref_coH0, ref_coL0, ref_sH0, ref_sL0 : std_logic := '0';
  signal ref_coH1, ref_coL1, ref_sH1, ref_sL1 : std_logic := '0';
  signal ref_cout_final : std_logic := '0';

  function to_rail (b : integer) return std_logic is
  begin
    if b = 1 then return '1'; else return '0'; end if;
  end function;

  -- NCL TH23 with hysteresis: fires on majority, resets on all LOW,
  -- else holds previous output.
  function th23_ncl (a, b, c, prev : std_logic) return std_logic is
  begin
    if (a = '1' and b = '1') or (a = '1' and c = '1') or (b = '1' and c = '1') then
      return '1';
    elsif a = '0' and b = '0' and c = '0' then
      return '0';
    else
      return prev;
    end if;
  end function;

  -- NCL TH34W2 with hysteresis: fires on (A·B)|(A·C)|(A·D)|(B·C·D),
  -- resets on all LOW, else holds.
  function th34w2_ncl (a, b, c, d, prev : std_logic) return std_logic is
  begin
    if (a = '1' and b = '1') or (a = '1' and c = '1') or (a = '1' and d = '1')
       or (b = '1' and c = '1' and d = '1') then
      return '1';
    elsif a = '0' and b = '0' and c = '0' and d = '0' then
      return '0';
    else
      return prev;
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
    -- During NULL phase, pass the raw cell output through unmodified;
    -- reference values are only valid during DATA.
    if not active then return raw; end if;
    if rail_ok(raw.voltage, ref) then return raw; end if;
    if ref = '1' then
      return (voltage => VDD_V, resistance => 1.0e3, flags => AFL_KNOWN);
    else
      return (voltage => 0.0, resistance => 1.0e3, flags => AFL_KNOWN);
    end if;
  end function;

begin

  VDD <= (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= ZERO_L3DA;

  -- ----------------------------------------------------------------
  -- Hysteresis-aware reference. NCL 4-phase: during NULL all cells
  -- reset to '0'; during DATA they compute th*_ncl from previous state.
  -- `data_phase` signal tells us which phase we're in — when it drops
  -- (NULL) we clear all ref_* to 0.
  -- ----------------------------------------------------------------
  ref_proc : process (test_a, test_b, test_ci, data_phase)
    variable aH0b, aL0b, bH0b, bL0b : std_logic;
    variable aH1b, aL1b, bH1b, bL1b : std_logic;
    variable ciHb, ciLb : std_logic;
    variable ciH1b, ciL1b : std_logic;
  begin
    if not data_phase then
      ref_coH0 <= '0'; ref_coL0 <= '0';
      ref_sH0  <= '0'; ref_sL0  <= '0';
      ref_coH1 <= '0'; ref_coL1 <= '0';
      ref_sH1  <= '0'; ref_sL1  <= '0';
      ref_cout_final <= '0';
    else
    aH0b := to_rail((test_a / 1) mod 2);  aL0b := to_rail(1 - ((test_a / 1) mod 2));
    aH1b := to_rail((test_a / 2) mod 2);  aL1b := to_rail(1 - ((test_a / 2) mod 2));
    bH0b := to_rail((test_b / 1) mod 2);  bL0b := to_rail(1 - ((test_b / 1) mod 2));
    bH1b := to_rail((test_b / 2) mod 2);  bL1b := to_rail(1 - ((test_b / 2) mod 2));
    ciHb := to_rail(test_ci);             ciLb := to_rail(1 - test_ci);

    ref_coH0 <= th23_ncl(aH0b, bH0b, ciHb, ref_coH0);
    ref_coL0 <= th23_ncl(aL0b, bL0b, ciLb, ref_coL0);
    -- For sum cells, the "A" input is the own-bit carry-out rail.
    -- Use the next-reference value so the sum reference stays consistent
    -- with what the cell would see at steady state.
    ref_sH0  <= th34w2_ncl(th23_ncl(aL0b, bL0b, ciLb, ref_coL0),
                           aH0b, bH0b, ciHb, ref_sH0);
    ref_sL0  <= th34w2_ncl(th23_ncl(aH0b, bH0b, ciHb, ref_coH0),
                           aL0b, bL0b, ciLb, ref_sL0);

    ciH1b := th23_ncl(aH0b, bH0b, ciHb, ref_coH0);
    ciL1b := th23_ncl(aL0b, bL0b, ciLb, ref_coL0);

    ref_coH1 <= th23_ncl(aH1b, bH1b, ciH1b, ref_coH1);
    ref_coL1 <= th23_ncl(aL1b, bL1b, ciL1b, ref_coL1);
    ref_sH1  <= th34w2_ncl(th23_ncl(aL1b, bL1b, ciL1b, ref_coL1),
                           aH1b, bH1b, ciH1b, ref_sH1);
    ref_sL1  <= th34w2_ncl(th23_ncl(aH1b, bH1b, ciH1b, ref_coH1),
                           aL1b, bL1b, ciL1b, ref_sL1);
    ref_cout_final <= th23_ncl(aH1b, bH1b, ciH1b, ref_coH1);
    end if;
  end process;

  -- ----------------------------------------------------------------
  -- DUT: 2-bit NCL adder.
  -- Bit 0 uses cinH/cinL as carry-in.
  -- Bit 1 uses CORRECTED carry — so if bit 0's async cells fail,
  -- bit 1 still sees the right carry and only its own cells are
  -- diagnosed.
  -- ----------------------------------------------------------------
  fa0 : entity work.nclfa_hybrid_evt
    port map (aH => aH0, aL => aL0, bH => bH0, bL => bL0,
              ciH => cinH, ciL => cinL,
              VDD => VDD, VSS => VSS,
              sH_drv => sH0_raw, sH_cap => sH0_cap,
              sL_drv => sL0_raw, sL_cap => sL0_cap,
              coH_drv => coH0_raw, coH_cap => coH0_cap,
              coL_drv => coL0_raw, coL_cap => coL0_cap,
              vdd_drv_coh => vdd0_coh, vdd_drv_col => vdd0_col,
              vdd_drv_sh => vdd0_sh, vdd_drv_sl => vdd0_sl);

  -- Carry correction: inject expected rail if raw is wrong — only
  -- during DATA phase, so NULL resets propagate unchanged.
  ciH1_corrected <= corrected(coH0_raw, ref_coH0, data_phase);
  ciL1_corrected <= corrected(coL0_raw, ref_coL0, data_phase);

  fa1 : entity work.nclfa_hybrid_evt
    port map (aH => aH1, aL => aL1, bH => bH1, bL => bL1,
              ciH => ciH1_corrected, ciL => ciL1_corrected,
              VDD => VDD, VSS => VSS,
              sH_drv => sH1_raw, sH_cap => sH1_cap,
              sL_drv => sL1_raw, sL_cap => sL1_cap,
              coH_drv => coH1_raw, coH_cap => coH1_cap,
              coL_drv => coL1_raw, coL_cap => coL1_cap,
              vdd_drv_coh => vdd1_coh, vdd_drv_col => vdd1_col,
              vdd_drv_sh => vdd1_sh, vdd_drv_sl => vdd1_sl);

  -- ----------------------------------------------------------------
  -- Stimulus + check/correct process.
  -- ----------------------------------------------------------------
  stim_check : process
    constant HI : logic3da := (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
    constant LO : logic3da := (voltage => 0.0,   resistance => 0.0, flags => AFL_KNOWN);
    type c_t is record
      a, b, ci, sum, cout : integer;
    end record;
    type c_arr is array (natural range <>) of c_t;
    constant cases : c_arr := (
      (0, 0, 0, 0, 0),
      (1, 1, 0, 2, 0),
      (2, 1, 0, 3, 0),
      (3, 1, 0, 0, 1)
    );
    variable mismatches : integer := 0;

    procedure nullify_in is
    begin
      data_phase <= false;
      aH0 <= ZERO_L3DA; aL0 <= ZERO_L3DA;
      bH0 <= ZERO_L3DA; bL0 <= ZERO_L3DA;
      aH1 <= ZERO_L3DA; aL1 <= ZERO_L3DA;
      bH1 <= ZERO_L3DA; bL1 <= ZERO_L3DA;
      cinH <= ZERO_L3DA; cinL <= ZERO_L3DA;
    end procedure;

    procedure apply (av, bv, ci : integer) is
    begin
      test_a <= av; test_b <= bv; test_ci <= ci;
      data_phase <= true;
      -- Bit 0
      if ((av / 1) mod 2) = 1 then aH0 <= HI; aL0 <= LO;
      else                          aH0 <= LO; aL0 <= HI; end if;
      if ((bv / 1) mod 2) = 1 then bH0 <= HI; bL0 <= LO;
      else                          bH0 <= LO; bL0 <= HI; end if;
      -- Bit 1
      if ((av / 2) mod 2) = 1 then aH1 <= HI; aL1 <= LO;
      else                          aH1 <= LO; aL1 <= HI; end if;
      if ((bv / 2) mod 2) = 1 then bH1 <= HI; bL1 <= LO;
      else                          bH1 <= LO; bL1 <= HI; end if;
      if ci = 1 then cinH <= HI; cinL <= LO;
      else           cinH <= LO; cinL <= HI; end if;
    end procedure;

    procedure check_and_report (name : string; raw_v : real; ref : std_logic) is
    begin
      if not rail_ok(raw_v, ref) then
        mismatches := mismatches + 1;
        report "  MISMATCH at " & name & ": got=" & real'image(raw_v)
             & " expect=" & std_logic'image(ref) severity warning;
      end if;
    end procedure;

  begin
    for i in cases'range loop
      nullify_in;
      wait for 30 ns;
      apply(cases(i).a, cases(i).b, cases(i).ci);
      wait for 60 ns;

      report "case " & integer'image(cases(i).a) & " + "
             & integer'image(cases(i).b) & " + "
             & integer'image(cases(i).ci)
             & "  carry into bit1: raw(H,L)=(" & real'image(coH0_raw.voltage)
             & "," & real'image(coL0_raw.voltage)
             & ")  corrected(H,L)=(" & real'image(ciH1_corrected.voltage)
             & "," & real'image(ciL1_corrected.voltage) & ")";
      check_and_report("bit0 coH", coH0_raw.voltage, ref_coH0);
      check_and_report("bit0 coL", coL0_raw.voltage, ref_coL0);
      check_and_report("bit0 sH",  sH0_raw.voltage,  ref_sH0);
      check_and_report("bit0 sL",  sL0_raw.voltage,  ref_sL0);
      check_and_report("bit1 coH", coH1_raw.voltage, ref_coH1);
      check_and_report("bit1 coL", coL1_raw.voltage, ref_coL1);
      check_and_report("bit1 sH",  sH1_raw.voltage,  ref_sH1);
      check_and_report("bit1 sL",  sL1_raw.voltage,  ref_sL1);
    end loop;

    if mismatches = 0 then
      report "ALL " & integer'image(cases'length) & " cases clean";
    else
      report integer'image(mismatches) & " cell-level mismatches" severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
