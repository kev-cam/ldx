-- tb_ncl_add2_hybrid_evt_nvc.vhd — 2-bit ripple-carry adder (minimal
-- multi-FA test). Probes whether the async bug surfaces at depth 2
-- (simpler to debug) or only deeper.

library ieee;
use ieee.math_real.all;

use work.logic3d_types_pkg.all;
use work.logic3ds_pkg.all;
use work.logic3da_pkg.all;

entity tb_ncl_add2_hybrid_evt_nvc is
end entity;

architecture sim of tb_ncl_add2_hybrid_evt_nvc is
  constant ZERO_L3DA : logic3da := (voltage => 0.0, resistance => 0.0,
                                    flags => AFL_KNOWN);
  constant VDD_V : real := 1.2;

  type l3da_2 is array (0 to 1) of resolved_logic3da;
  signal aH, aL, bH, bL, sH, sL : l3da_2 := (others => ZERO_L3DA);
  type l3da_3 is array (0 to 2) of resolved_logic3da;
  signal cH, cL : l3da_3 := (others => ZERO_L3DA);
  signal cinH, cinL : resolved_logic3da := ZERO_L3DA;

  signal VDD : resolved_logic3da := (voltage => VDD_V, resistance => 0.0,
                                     flags => AFL_KNOWN);
  signal VSS : resolved_logic3da := ZERO_L3DA;

  type l3da_arr is array (natural range <>) of logic3da;
  type real_arr is array (natural range <>) of real;
  signal fa_sH_drv, fa_sL_drv, fa_coH_drv, fa_coL_drv : l3da_arr(0 to 1) := (others => ZERO_L3DA);
  signal fa_sH_cap, fa_sL_cap, fa_coH_cap, fa_coL_cap : real_arr(0 to 1) := (others => 0.0);
  signal fa_v_coh, fa_v_col, fa_v_sh, fa_v_sl : l3da_arr(0 to 1) := (others => ZERO_L3DA);
begin

  VDD <= (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
  VSS <= (voltage => 0.0, resistance => 0.0, flags => AFL_KNOWN);

  cH(0) <= cinH;
  cL(0) <= cinL;
  -- Add a 1 ps explicit delay so that each carry-chain stage advances
  -- in its own scheduled tick. This avoids zero-delta races where bit N
  -- wakes on its stimulus inputs with the still-stale bit N-1 carry in
  -- the same delta cycle.
  cH(1) <= fa_coH_drv(0) after 1 ps;
  cL(1) <= fa_coL_drv(0) after 1 ps;
  cH(2) <= fa_coH_drv(1) after 1 ps;
  cL(2) <= fa_coL_drv(1) after 1 ps;

  fa_gen : for i in 0 to 1 generate
    u : entity work.nclfa_hybrid_evt
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
    sH(i) <= fa_sH_drv(i);
    sL(i) <= fa_sL_drv(i);
  end generate;

  stim : process
    constant HI : logic3da := (voltage => VDD_V, resistance => 0.0, flags => AFL_KNOWN);
    constant LO : logic3da := (voltage => 0.0,   resistance => 0.0, flags => AFL_KNOWN);

    procedure nullify is
    begin
      aH(0) <= ZERO_L3DA; aL(0) <= ZERO_L3DA;
      aH(1) <= ZERO_L3DA; aL(1) <= ZERO_L3DA;
      bH(0) <= ZERO_L3DA; bL(0) <= ZERO_L3DA;
      bH(1) <= ZERO_L3DA; bL(1) <= ZERO_L3DA;
      cinH <= ZERO_L3DA; cinL <= ZERO_L3DA;
    end procedure;

    procedure drive_bit0 (bitval : integer) is
    begin
      if bitval = 1 then
        aH(0) <= HI; aL(0) <= LO;
      else
        aH(0) <= LO; aL(0) <= HI;
      end if;
    end procedure;
    -- (unrolled per bit so indices are static — see NVC §4.2.2.3)

    procedure set_case (av, bv, ci : integer) is
    begin
      report "set_case av=" & integer'image(av) & " bv=" & integer'image(bv)
             & " ci=" & integer'image(ci);
      if ((av / 1) mod 2) = 1 then
        aH(0) <= HI; aL(0) <= LO;
      else
        aH(0) <= LO; aL(0) <= HI;
      end if;
      if ((av / 2) mod 2) = 1 then
        aH(1) <= HI; aL(1) <= LO;
        report "  bit1 of av=1: aH(1)<=HI, aL(1)<=LO";
      else
        aH(1) <= LO; aL(1) <= HI;
        report "  bit1 of av=0: aH(1)<=LO, aL(1)<=HI";
      end if;
      if ((bv / 1) mod 2) = 1 then
        bH(0) <= HI; bL(0) <= LO;
      else
        bH(0) <= LO; bL(0) <= HI;
      end if;
      if ((bv / 2) mod 2) = 1 then
        bH(1) <= HI; bL(1) <= LO;
      else
        bH(1) <= LO; bL(1) <= HI;
      end if;
      if ci = 1 then
        cinH <= HI; cinL <= LO;
      else
        cinH <= LO; cinL <= HI;
      end if;
    end procedure;

  begin
    nullify;           wait for 30 ns;
    set_case(0,  0, 0); wait for 60 ns;  -- 0+0=0
    nullify;           wait for 30 ns;
    set_case(1,  1, 0); wait for 60 ns;  -- 1+1=2
    nullify;           wait for 30 ns;
    set_case(2,  1, 0); wait for 60 ns;  -- 2+1=3
    nullify;           wait for 30 ns;
    set_case(3,  1, 0); wait for 60 ns;  -- 3+1=0 cout=1 (4-bit overflow in 2-bit)
    nullify;           wait for 30 ns;
    wait;
  end process;

  report_proc : process
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
    wait for 85 ns;
    for i in cases'range loop
      got_s := 0;
      for b in 0 to 1 loop
        bit_val := dec(sH(b).voltage, sL(b).voltage);
        if bit_val < 0 then got_s := -1; exit; end if;
        got_s := got_s + bit_val * (2**b);
      end loop;
      got_c := dec(fa_coH_drv(1).voltage, fa_coL_drv(1).voltage);
      report "case " & integer'image(cases(i).a) & " + "
             & integer'image(cases(i).b) & " + "
             & integer'image(cases(i).ci) & " = "
             & integer'image(cases(i).sum) & " cout="
             & integer'image(cases(i).cout)
             & "  got sum=" & integer'image(got_s)
             & " cout=" & integer'image(got_c);
      for b in 0 to 1 loop
        report "    bit " & integer'image(b)
             & " aH=" & real'image(aH(b).voltage)
             & " aL=" & real'image(aL(b).voltage)
             & " bH=" & real'image(bH(b).voltage)
             & " bL=" & real'image(bL(b).voltage)
             & " ciH=" & real'image(cH(b).voltage)
             & " ciL=" & real'image(cL(b).voltage)
             & " | sH=" & real'image(sH(b).voltage)
             & " sL=" & real'image(sL(b).voltage)
             & " coH=" & real'image(fa_coH_drv(b).voltage)
             & " coL=" & real'image(fa_coL_drv(b).voltage);
      end loop;
      if got_s /= cases(i).sum  then fails := fails + 1; end if;
      if got_c /= cases(i).cout then fails := fails + 1; end if;
      wait for 90 ns;
    end loop;
    if fails = 0 then report "ALL " & integer'image(cases'length) & " CASES correct";
    else report integer'image(fails) & " failures" severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
