-- tb_ncl_add4_nn_hybrid_nvc.vhd — 4-bit ripple-carry NCL adder built
-- from 4× nclfa_nn_hybrid instances. Proves the NN-hybrid cells scale
-- across multiple stages: carry propagates through 4 sequential full
-- adders, 16 cell instances total (8 TH23 + 8 TH34W2).

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_ncl_add4_nn_hybrid_nvc is
end entity;

architecture sim of tb_ncl_add4_nn_hybrid_nvc is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);
  constant VDD_V : real := 1.2;

  -- Dual-rail 4-bit nets.
  type l3da_4 is array (0 to 3) of resolved_logic3da;
  signal aH, aL : l3da_4 := (others => ZERO_L3DA);
  signal bH, bL : l3da_4 := (others => ZERO_L3DA);
  signal sH, sL : l3da_4 := (others => ZERO_L3DA);
  -- Carry chain: nets 0..4 (0 = cin, 1..3 intermediate, 4 = cout).
  signal cH : l3da_4 := (others => ZERO_L3DA);
  signal cL : l3da_4 := (others => ZERO_L3DA);
  signal coH_final, coL_final : resolved_logic3da := ZERO_L3DA;

  signal cinH : resolved_logic3da := ZERO_L3DA;
  signal cinL : resolved_logic3da := ZERO_L3DA;

  signal VDD : resolved_logic3da := (voltage => VDD_V, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  -- Per-cell driver exposures; we don't resolve them but entity ports
  -- need something to write to.
  type l3da_arr is array (natural range <>) of logic3da;
  type real_arr is array (natural range <>) of real;
  signal fa_sH_drv, fa_sL_drv, fa_coH_drv, fa_coL_drv : l3da_arr(0 to 3) := (others => ZERO_L3DA);
  signal fa_sH_cap, fa_sL_cap, fa_coH_cap, fa_coL_cap : real_arr(0 to 3) := (others => 0.0);
  signal fa_v_coh, fa_v_col, fa_v_sh, fa_v_sl : l3da_arr(0 to 3) := (others => ZERO_L3DA);

begin

  VDD <= (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= (voltage => 0.0, resistance => 0.0, flags => AFL_KNOWN);

  -- ---- Stimulus: 4-phase NCL. Inputs NULL → DATA per test case ----
  stim : process
    constant HI : logic3da := (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
    constant LO : logic3da := (voltage => 0.0,   resistance => 0.0, flags => AFL_KNOWN);

    procedure nullify is
    begin
      for i in 0 to 3 loop
        aH(i) <= ZERO_L3DA; aL(i) <= ZERO_L3DA;
        bH(i) <= ZERO_L3DA; bL(i) <= ZERO_L3DA;
      end loop;
      cinH <= ZERO_L3DA; cinL <= ZERO_L3DA;
    end procedure;

    procedure set_case (av, bv, ci : integer) is
      variable abit, bbit : integer;
    begin
      for i in 0 to 3 loop
        abit := (av / (2**i)) mod 2;
        bbit := (bv / (2**i)) mod 2;
        if abit = 1 then
          aH(i) <= HI; aL(i) <= LO;
        else
          aH(i) <= LO; aL(i) <= HI;
        end if;
        if bbit = 1 then
          bH(i) <= HI; bL(i) <= LO;
        else
          bH(i) <= LO; bL(i) <= HI;
        end if;
      end loop;
      if ci = 1 then cinH <= HI; cinL <= LO;
      else           cinH <= LO; cinL <= HI;
      end if;
    end procedure;

  begin
    nullify;           wait for 30 ns;
    set_case(0,  0, 0); wait for 60 ns;  -- 0 + 0 = 0
    nullify;           wait for 30 ns;
    set_case(1,  1, 0); wait for 60 ns;  -- 1 + 1 = 2
    nullify;           wait for 30 ns;
    set_case(3,  4, 0); wait for 60 ns;  -- 3 + 4 = 7
    nullify;           wait for 30 ns;
    set_case(7,  8, 0); wait for 60 ns;  -- 7 + 8 = 15
    nullify;           wait for 30 ns;
    set_case(15, 1, 0); wait for 60 ns;  -- 15 + 1 = 0 cout=1
    nullify;           wait for 30 ns;
    set_case(9,  5, 1); wait for 60 ns;  -- 9 + 5 + 1 = 15
    nullify;           wait for 30 ns;
    set_case(15,15, 1); wait for 60 ns;  -- 15+15+1 = 31 → sum=15 cout=1
    nullify;           wait for 30 ns;
    wait;
  end process;

  -- Carry chain: cinH/cinL feed cH(0)/cL(0); each fa(i) takes cH(i)/cL(i)
  -- and produces cH(i+1)/cL(i+1). Final cH(3)/cL(3) output is cout.
  cH(0) <= cinH;
  cL(0) <= cinL;

  -- ---- Four NCL-FA instances ----
  fa_gen : for i in 0 to 3 generate
    u : entity work.nclfa_nn_hybrid
      port map (
        aH => aH(i), aL => aL(i), bH => bH(i), bL => bL(i),
        ciH => cH(i), ciL => cL(i),
        VDD => VDD, VSS => VSS,
        sH_drv => fa_sH_drv(i), sH_cap => fa_sH_cap(i),
        sL_drv => fa_sL_drv(i), sL_cap => fa_sL_cap(i),
        coH_drv => fa_coH_drv(i), coH_cap => fa_coH_cap(i),
        coL_drv => fa_coL_drv(i), coL_cap => fa_coL_cap(i),
        vdd_drv_coh => fa_v_coh(i), vdd_drv_col => fa_v_col(i),
        vdd_drv_sh  => fa_v_sh(i),  vdd_drv_sl  => fa_v_sl(i));

    -- Sum outputs for this bit.
    sH(i) <= fa_sH_drv(i);
    sL(i) <= fa_sL_drv(i);
  end generate;

  -- Carry chain: each FA's carry-out becomes the next FA's carry-in.
  cH(1) <= fa_coH_drv(0);
  cL(1) <= fa_coL_drv(0);
  cH(2) <= fa_coH_drv(1);
  cL(2) <= fa_coL_drv(1);
  cH(3) <= fa_coH_drv(2);
  cL(3) <= fa_coL_drv(2);

  coH_final <= fa_coH_drv(3);
  coL_final <= fa_coL_drv(3);

  -- ---- Checker ----
  report_proc : process
    type c_t is record
      a, b, ci, sum, cout : integer;
    end record;
    type c_arr is array (natural range <>) of c_t;
    constant cases : c_arr := (
      (0, 0, 0,  0, 0),
      (1, 1, 0,  2, 0),
      (3, 4, 0,  7, 0),
      (7, 8, 0, 15, 0),
      (15,1, 0,  0, 1),
      (9, 5, 1, 15, 0),
      (15,15,1, 15, 1)
    );

    function dec (H, L : real) return integer is
    begin
      if    H > VDD_V/2.0 and L < VDD_V/2.0 then return 1;
      elsif H < VDD_V/2.0 and L > VDD_V/2.0 then return 0;
      else  return -1;
      end if;
    end function;

    variable got_s, got_c, bit_val : integer;
    variable fails : integer := 0;

  begin
    -- Line up to middle of first DATA window: 30 ns NULL + ~55 ns into DATA.
    wait for 85 ns;
    for i in cases'range loop
      got_s := 0;
      for b in 0 to 3 loop
        bit_val := dec(sH(b).voltage, sL(b).voltage);
        if bit_val < 0 then got_s := -1; exit; end if;
        got_s := got_s + bit_val * (2**b);
      end loop;
      got_c := dec(coH_final.voltage, coL_final.voltage);
      report "case " & integer'image(cases(i).a) & " + "
             & integer'image(cases(i).b) & " + "
             & integer'image(cases(i).ci) & " = "
             & integer'image(cases(i).sum) & " cout="
             & integer'image(cases(i).cout)
             & "  got sum=" & integer'image(got_s)
             & " cout=" & integer'image(got_c);
      if got_s /= cases(i).sum  then fails := fails + 1; end if;
      if got_c /= cases(i).cout then fails := fails + 1; end if;
      wait for 90 ns;  -- advance: 60ns DATA tail + 30ns NULL
    end loop;

    if fails = 0 then
      report "ALL " & integer'image(cases'length) & " CASES correct";
    else
      report integer'image(fails) & " failures"
        severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
