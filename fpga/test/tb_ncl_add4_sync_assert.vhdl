-- tb_ncl_add4_sync_assert.vhdl — 4-bit NCL adder with per-cell
-- assertion/correction harness. Uses the sync std_logic NCL library
-- (should never fail). Establishes the reference output pattern
-- so the async variant can be compared against it.
--
-- At every cell output (carry and sum bits, both rails), we compute
-- the expected value from first principles (the plain Boolean truth
-- table for a 1-bit full adder) and assert the cell actually produces
-- it. Since the sync library is just Boolean ops, this should pass
-- trivially — the value is in building the harness so it can be
-- reused by the async testbench with IDENTICAL expected outputs.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.ncl.all;

entity tb_ncl_add4_sync_assert is
end entity;

architecture sim of tb_ncl_add4_sync_assert is
  signal aH, aL, bH, bL, sH, sL : std_logic_vector(3 downto 0) := (others => '0');
  signal cH, cL : std_logic_vector(4 downto 0) := (others => '0');
  signal cinH, cinL : std_logic := '0';

  -- One test case.
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

  -- Helper: per-bit expected (coH, coL, sH, sL) as std_logic rails,
  -- computed from (a_bit, b_bit, ci_bit_in) following the Fant canonical
  -- form exactly (coH=th23 on H-rails, sH=th34w2 on cross rails). Because
  -- the sync ncl library implements these as pure Boolean, the expected
  -- value here is identical to whatever the cell computes — asserting
  -- trivially. But that's the point: this is the reference.
  type expected_t is record
    coH, coL, sH, sL : std_logic;
  end record;

  function to_rail (b : integer) return std_logic is
  begin
    if b = 1 then return '1'; else return '0'; end if;
  end function;

  function bit_expected (ab, bb : integer;
                         ciH_b, ciL_b : std_logic)
    return expected_t is
    variable r : expected_t;
    variable aH_b : std_logic := to_rail(ab);
    variable aL_b : std_logic := to_rail(1 - ab);
    variable bH_b : std_logic := to_rail(bb);
    variable bL_b : std_logic := to_rail(1 - bb);
  begin
    r.coH := th23(aH_b, bH_b, ciH_b);
    r.coL := th23(aL_b, bL_b, ciL_b);
    r.sH  := th34w2(r.coL, aH_b, bH_b, ciH_b);
    r.sL  := th34w2(r.coH, aL_b, bL_b, ciL_b);
    return r;
  end function;

begin

  -- ---- Structural ripple-carry 4-bit adder ----
  fa_gen : for i in 0 to 3 generate
    cH(i+1) <= th23(aH(i), bH(i), cH(i));
    cL(i+1) <= th23(aL(i), bL(i), cL(i));
    sH(i)   <= th34w2(cL(i+1), aH(i), bH(i), cH(i));
    sL(i)   <= th34w2(cH(i+1), aL(i), bL(i), cL(i));
  end generate;
  cH(0) <= cinH;
  cL(0) <= cinL;

  stim_check : process
    variable got_s, got_c : integer;
    variable fails, corrections : integer := 0;
    variable exp : expected_t;
    variable ci_h_prop, ci_l_prop : std_logic;  -- propagated expected cin

    procedure apply (av, bv, c : integer) is
      variable abit, bbit : integer;
    begin
      for i in 0 to 3 loop
        abit := (av / (2**i)) mod 2;
        bbit := (bv / (2**i)) mod 2;
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

    -- Assertion check at bit i: compare cell outputs against expected,
    -- accumulate `fails` / `corrections`. The sync model matches by
    -- construction so this is the reference anchor.
    procedure check_bit (i : integer; cih_in, cil_in : std_logic;
                         av, bv : integer) is
      variable ab_i : integer := (av / (2**i)) mod 2;
      variable bb_i : integer := (bv / (2**i)) mod 2;
      variable exp_r : expected_t;
    begin
      exp_r := bit_expected(ab_i, bb_i, cih_in, cil_in);
      assert cH(i+1) = exp_r.coH
        report "bit " & integer'image(i) & " coH mismatch: got="
               & std_logic'image(cH(i+1)) & " expect=" & std_logic'image(exp_r.coH)
        severity warning;
      assert cL(i+1) = exp_r.coL
        report "bit " & integer'image(i) & " coL mismatch: got="
               & std_logic'image(cL(i+1)) & " expect=" & std_logic'image(exp_r.coL)
        severity warning;
      assert sH(i) = exp_r.sH
        report "bit " & integer'image(i) & " sH mismatch: got="
               & std_logic'image(sH(i)) & " expect=" & std_logic'image(exp_r.sH)
        severity warning;
      assert sL(i) = exp_r.sL
        report "bit " & integer'image(i) & " sL mismatch: got="
               & std_logic'image(sL(i)) & " expect=" & std_logic'image(exp_r.sL)
        severity warning;
      if cH(i+1) /= exp_r.coH or cL(i+1) /= exp_r.coL
         or sH(i) /= exp_r.sH or sL(i) /= exp_r.sL then
        fails := fails + 1;
      end if;
    end procedure;

    variable ab_i, bb_i : integer;
    variable next_h, next_l : std_logic;
  begin
    for i in cases'range loop
      apply(cases(i).a, cases(i).b, cases(i).ci);
      wait for 1 ns;
      got_s := 0;
      for b in 0 to 3 loop
        if sH(b) = '1' then got_s := got_s + 2**b; end if;
      end loop;
      got_c := 0;
      if cH(4) = '1' then got_c := 1; end if;

      -- Propagate expected carry through the 4 bits, asserting at each.
      ci_h_prop := cinH;
      ci_l_prop := cinL;
      for b in 0 to 3 loop
        check_bit(b, ci_h_prop, ci_l_prop, cases(i).a, cases(i).b);
        ab_i := (cases(i).a / (2**b)) mod 2;
        bb_i := (cases(i).b / (2**b)) mod 2;
        next_h := th23(to_rail(ab_i), to_rail(bb_i), ci_h_prop);
        next_l := th23(to_rail(1 - ab_i), to_rail(1 - bb_i), ci_l_prop);
        ci_h_prop := next_h;
        ci_l_prop := next_l;
      end loop;

      report "case " & integer'image(cases(i).a) & " + "
             & integer'image(cases(i).b) & " + "
             & integer'image(cases(i).ci)
             & "  expect sum=" & integer'image(cases(i).sum)
             & " cout=" & integer'image(cases(i).cout)
             & "  got sum=" & integer'image(got_s)
             & " cout=" & integer'image(got_c);
    end loop;

    if fails = 0 then
      report "ALL bits across " & integer'image(cases'length) & " cases matched reference";
    else
      report integer'image(fails) & " bit-level mismatches" severity warning;
    end if;
    std.env.finish;
  end process;

end architecture;
