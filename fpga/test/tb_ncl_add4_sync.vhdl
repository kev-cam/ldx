-- tb_ncl_add4_sync.vhdl — Stage-1 validation of the 4-bit NCL ripple
-- adder wiring, using the synchronous (std_logic-based) NCL package.
--
-- Purpose: confirm the adder wiring is functionally correct independent
-- of any analog / event-driven semantics. The async NN-hybrid version
-- in tb_ncl_add4_nn_hybrid_nvc has the same structural topology — if
-- this sync variant passes 8/8 cases, any residual async failure is in
-- stage 2 (event propagation / cell numerics), not in the wiring.
--
-- Uses work.ncl (the ncl_sync flavour) where th23/th34w2 are plain
-- Boolean functions. Dual-rail signals are carried through but only
-- the H rails contribute (L is unused in sync synthesis).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.ncl.all;

entity tb_ncl_add4_sync is
end entity;

architecture sim of tb_ncl_add4_sync is
  -- 4-bit dual-rail busses on H and L rails. L rails carry the NCL
  -- encoding (1 = DATA0, 0 otherwise) but sync logic ignores them.
  signal aH, aL, bH, bL, sH, sL : std_logic_vector(3 downto 0) := (others => '0');
  signal cH, cL : std_logic_vector(4 downto 0) := (others => '0');
  signal cinH, cinL : std_logic := '0';

  -- ---- Stimulus + expected table ----
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
    (15,15,1, 15, 1),
    (10,5, 0, 15, 0)
  );

begin

  -- ---- Structural NCL full adder per bit ----
  -- coH[i+1] = th23(aH[i], bH[i], cH[i])
  -- coL[i+1] = th23(aL[i], bL[i], cL[i])
  -- sH[i]    = th34w2(coL[i+1], aH[i], bH[i], cH[i])
  -- sL[i]    = th34w2(coH[i+1], aL[i], bL[i], cL[i])
  --
  -- (Matches nclfa_nn_hybrid.vhd port ordering exactly.)
  fa_gen : for i in 0 to 3 generate
    cH(i+1) <= th23(aH(i), bH(i), cH(i));
    cL(i+1) <= th23(aL(i), bL(i), cL(i));
    sH(i)   <= th34w2(cL(i+1), aH(i), bH(i), cH(i));
    sL(i)   <= th34w2(cH(i+1), aL(i), bL(i), cL(i));
  end generate;

  cH(0) <= cinH;
  cL(0) <= cinL;

  -- ---- Stimulus + checker ----
  stim_check : process
    variable got_s, got_c : integer;
    variable fails : integer := 0;
    variable av, bv, ci : integer;

    procedure apply (a, b, c : integer) is
      variable abit, bbit : integer;
    begin
      for i in 0 to 3 loop
        abit := (a / (2**i)) mod 2;
        bbit := (b / (2**i)) mod 2;
        if abit = 1 then aH(i) <= '1'; aL(i) <= '0';
        else             aH(i) <= '0'; aL(i) <= '1';
        end if;
        if bbit = 1 then bH(i) <= '1'; bL(i) <= '0';
        else             bH(i) <= '0'; bL(i) <= '1';
        end if;
      end loop;
      if c = 1 then cinH <= '1'; cinL <= '0';
      else          cinH <= '0'; cinL <= '1';
      end if;
    end procedure;

  begin
    for i in cases'range loop
      apply(cases(i).a, cases(i).b, cases(i).ci);
      wait for 1 ns;  -- let combinational logic settle
      got_s := 0;
      for b in 0 to 3 loop
        if sH(b) = '1' then got_s := got_s + 2**b; end if;
      end loop;
      got_c := 0;
      if cH(4) = '1' then got_c := 1; end if;
      report "case " & integer'image(cases(i).a) & " + "
             & integer'image(cases(i).b) & " + "
             & integer'image(cases(i).ci)
             & "  expect sum=" & integer'image(cases(i).sum)
             & " cout=" & integer'image(cases(i).cout)
             & "  got sum=" & integer'image(got_s)
             & " cout=" & integer'image(got_c);
      if got_s /= cases(i).sum  then fails := fails + 1; end if;
      if got_c /= cases(i).cout then fails := fails + 1; end if;
    end loop;

    if fails = 0 then
      report "ALL " & integer'image(cases'length) & " CASES correct";
    else
      report integer'image(fails) & " failures" severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
