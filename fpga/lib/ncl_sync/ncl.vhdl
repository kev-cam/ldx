-- ncl.vhdl (ncl_sync variant) — synchronous-FPGA build of the NCL package.
--
-- Source-compatible with the NULL-Convention-Logic simulation package
-- (lib/ncl/ncl.vhdl): same package name, same types, same functions, same
-- semantics for the always-data case. The difference is internal:
--
--   * ncl_logic collapses to a single std_logic rail (the "H" rail).
--   * NCL_NULL is an alias for '0' — there are no spacers in synthesis.
--   * ncl_is_null is a constant 'false' (so dead-on-NULL branches in user
--     code optimize away cleanly during synthesis).
--   * Encode/decode are identity.
--   * Logic / arithmetic operators delegate to plain std_logic_vector ops.
--
-- This lets the same ARV CPU sources (regfile / decoder / execute /
-- arv_cpu) compile against either:
--
--   library ncl;     -- simulation: dual-rail with NULL waves
--   library ncl;     -- synthesis: this package, plain binary
--
-- by simply choosing which library directory to point Quartus / NVC at.
-- The phase-driven processes inside arv_cpu provide all the synchronous
-- breakpoints needed to make the design synthesisable on a clocked fabric.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

package ncl is

    -- Single-rail "ncl_logic" — just a wrapper record so the type name
    -- matches the simulation package and ARV ports compile unchanged.
    type ncl_logic is record
        H : std_logic;
    end record;

    type ncl_logic_vector is array (natural range <>) of ncl_logic;

    constant NCL_NULL  : ncl_logic := (H => '0');
    constant NCL_DATA0 : ncl_logic := (H => '0');
    constant NCL_DATA1 : ncl_logic := (H => '1');

    -- ---- State queries ----
    function ncl_is_null(d : ncl_logic)        return boolean;
    function ncl_is_null(d : ncl_logic_vector) return boolean;
    function ncl_is_null(d : ncl_logic)        return std_logic;
    function ncl_is_null(d : ncl_logic_vector) return std_logic_vector;
    function ncl_is_data(d : ncl_logic)        return boolean;
    function ncl_is_data(d : ncl_logic_vector) return boolean;
    function ncl_complete(d : ncl_logic_vector) return boolean;
    function ncl_complete(d : ncl_logic_vector) return std_logic;

    -- ---- Encode / Decode ----
    function ncl_encode(d : std_logic)        return ncl_logic;
    function ncl_encode(d : std_logic_vector) return ncl_logic_vector;
    function ncl_decode(d : ncl_logic)        return std_logic;
    function ncl_decode(d : ncl_logic_vector) return std_logic_vector;

    -- ---- Threshold gates: degenerate to plain Boolean primitives ----
    function th12(a, b : std_logic) return std_logic;
    function th22(a, b : std_logic) return std_logic;
    function th13(a, b, c : std_logic) return std_logic;
    function th23(a, b, c : std_logic) return std_logic;
    function th33(a, b, c : std_logic) return std_logic;
    function th24(a, b, c, d : std_logic) return std_logic;
    function th34(a, b, c, d : std_logic) return std_logic;
    function th44(a, b, c, d : std_logic) return std_logic;
    function th12w2(a, b : std_logic) return std_logic;
    function th23w2(a, b, c : std_logic) return std_logic;
    function th34w2(a, b, c, d : std_logic) return std_logic;

    -- ---- Logic operators (single-rail) ----
    function "and"  (l, r: ncl_logic) return ncl_logic;
    function "nand" (l, r: ncl_logic) return ncl_logic;
    function "or"   (l, r: ncl_logic) return ncl_logic;
    function "nor"  (l, r: ncl_logic) return ncl_logic;
    function "xor"  (l, r: ncl_logic) return ncl_logic;
    function "xnor" (l, r: ncl_logic) return ncl_logic;
    function "not"  (l   : ncl_logic) return ncl_logic;

    function "and"  (l, r: ncl_logic_vector) return ncl_logic_vector;
    function "nand" (l, r: ncl_logic_vector) return ncl_logic_vector;
    function "or"   (l, r: ncl_logic_vector) return ncl_logic_vector;
    function "nor"  (l, r: ncl_logic_vector) return ncl_logic_vector;
    function "xor"  (l, r: ncl_logic_vector) return ncl_logic_vector;
    function "xnor" (l, r: ncl_logic_vector) return ncl_logic_vector;
    function "not"  (l   : ncl_logic_vector) return ncl_logic_vector;

    function "="    (l, r: ncl_logic) return boolean;
    function "="    (l  : ncl_logic; r: std_logic) return boolean;

    -- ---- Arithmetic ----
    function ncl_add(a, b : ncl_logic_vector) return ncl_logic_vector;
    function ncl_sub(a, b : ncl_logic_vector) return ncl_logic_vector;
    function ncl_negate(a : ncl_logic_vector) return ncl_logic_vector;

    -- ---- Multiplexer ----
    function ncl_mux(sel : ncl_logic; a, b : ncl_logic_vector) return ncl_logic_vector;
    function ncl_mux(sel : ncl_logic_vector; a, b : ncl_logic_vector) return ncl_logic_vector;

    -- ---- Comparator ----
    function ncl_compare(a, b : ncl_logic_vector; op : string) return ncl_logic_vector;

    -- ---- Utility ----
    function ncl_null_vector(width : natural) return ncl_logic_vector;

end package ncl;

package body ncl is

    -- ---- State queries: synthesis is always "data" ----
    function ncl_is_null(d : ncl_logic) return boolean is
    begin return false; end function;

    function ncl_is_null(d : ncl_logic) return std_logic is
    begin return '0'; end function;

    function ncl_is_null(d : ncl_logic_vector) return boolean is
    begin return false; end function;

    function ncl_is_null(d : ncl_logic_vector) return std_logic_vector is
        variable r : std_logic_vector(d'range) := (others => '0');
    begin return r; end function;

    function ncl_is_data(d : ncl_logic) return boolean is
    begin return true; end function;

    function ncl_is_data(d : ncl_logic_vector) return boolean is
    begin return true; end function;

    function ncl_complete(d : ncl_logic_vector) return boolean is
    begin return true; end function;

    function ncl_complete(d : ncl_logic_vector) return std_logic is
    begin return '1'; end function;

    -- ---- Encode / Decode: identity on the H rail ----
    function ncl_encode(d : std_logic) return ncl_logic is
    begin return (H => d); end function;

    function ncl_encode(d : std_logic_vector) return ncl_logic_vector is
        variable r : ncl_logic_vector(d'range);
    begin
        for i in d'range loop r(i) := (H => d(i)); end loop;
        return r;
    end function;

    function ncl_decode(d : ncl_logic) return std_logic is
    begin return d.H; end function;

    function ncl_decode(d : ncl_logic_vector) return std_logic_vector is
        variable r : std_logic_vector(d'range);
    begin
        for i in d'range loop r(i) := d(i).H; end loop;
        return r;
    end function;

    -- ---- Threshold gates → ordinary boolean primitives ----
    function th12(a, b : std_logic) return std_logic is
    begin return a or b; end function;
    function th22(a, b : std_logic) return std_logic is
    begin return a and b; end function;
    function th13(a, b, c : std_logic) return std_logic is
    begin return a or b or c; end function;
    function th23(a, b, c : std_logic) return std_logic is
    begin return (a and b) or (a and c) or (b and c); end function;
    function th33(a, b, c : std_logic) return std_logic is
    begin return a and b and c; end function;
    function th24(a, b, c, d : std_logic) return std_logic is
    begin return (a and b) or (a and c) or (a and d)
              or (b and c) or (b and d) or (c and d); end function;
    function th34(a, b, c, d : std_logic) return std_logic is
    begin return (a and b and c) or (a and b and d)
              or (a and c and d) or (b and c and d); end function;
    function th44(a, b, c, d : std_logic) return std_logic is
    begin return a and b and c and d; end function;
    function th12w2(a, b : std_logic) return std_logic is
    begin return a or b; end function;
    function th23w2(a, b, c : std_logic) return std_logic is
    begin return a or (b and c); end function;
    function th34w2(a, b, c, d : std_logic) return std_logic is
    begin return (a and (b or c or d)) or (b and c and d); end function;

    -- ---- Logic ops on the H rail ----
    function "and"  (l, r: ncl_logic) return ncl_logic is
    begin return (H => l.H and r.H); end function;
    function "nand" (l, r: ncl_logic) return ncl_logic is
    begin return (H => l.H nand r.H); end function;
    function "or"   (l, r: ncl_logic) return ncl_logic is
    begin return (H => l.H or r.H); end function;
    function "nor"  (l, r: ncl_logic) return ncl_logic is
    begin return (H => l.H nor r.H); end function;
    function "xor"  (l, r: ncl_logic) return ncl_logic is
    begin return (H => l.H xor r.H); end function;
    function "xnor" (l, r: ncl_logic) return ncl_logic is
    begin return (H => l.H xnor r.H); end function;
    function "not"  (l   : ncl_logic) return ncl_logic is
    begin return (H => not l.H); end function;

    function "and" (l, r : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := l(i) and r(i); end loop; return o; end function;
    function "nand" (l, r : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := l(i) nand r(i); end loop; return o; end function;
    function "or" (l, r : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := l(i) or r(i); end loop; return o; end function;
    function "nor" (l, r : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := l(i) nor r(i); end loop; return o; end function;
    function "xor" (l, r : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := l(i) xor r(i); end loop; return o; end function;
    function "xnor" (l, r : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := l(i) xnor r(i); end loop; return o; end function;
    function "not" (l : ncl_logic_vector) return ncl_logic_vector is
        variable o : ncl_logic_vector(l'range);
    begin for i in l'range loop o(i) := not l(i); end loop; return o; end function;

    function "=" (l, r: ncl_logic) return boolean is
    begin return l.H = r.H; end function;

    function "=" (l: ncl_logic; r: std_logic) return boolean is
    begin return l.H = r; end function;

    -- ---- Utility ----
    function ncl_null_vector(width : natural) return ncl_logic_vector is
        variable r : ncl_logic_vector(width-1 downto 0) := (others => NCL_NULL);
    begin return r; end function;

    -- ---- Arithmetic via plain numeric_std ----
    function ncl_add(a, b : ncl_logic_vector) return ncl_logic_vector is
        variable av, bv, rv : std_logic_vector(a'length-1 downto 0);
    begin
        av := ncl_decode(a);
        bv := ncl_decode(b);
        rv := std_logic_vector(unsigned(av) + unsigned(bv));
        return ncl_encode(rv);
    end function;

    function ncl_negate(a : ncl_logic_vector) return ncl_logic_vector is
        variable av, rv : std_logic_vector(a'length-1 downto 0);
    begin
        av := ncl_decode(a);
        rv := std_logic_vector(-signed(av));
        return ncl_encode(rv);
    end function;

    function ncl_sub(a, b : ncl_logic_vector) return ncl_logic_vector is
        variable av, bv, rv : std_logic_vector(a'length-1 downto 0);
    begin
        av := ncl_decode(a);
        bv := ncl_decode(b);
        rv := std_logic_vector(unsigned(av) - unsigned(bv));
        return ncl_encode(rv);
    end function;

    function ncl_mux(sel : ncl_logic; a, b : ncl_logic_vector) return ncl_logic_vector is
    begin
        if sel.H = '1' then return a; else return b; end if;
    end function;

    function ncl_mux(sel : ncl_logic_vector; a, b : ncl_logic_vector) return ncl_logic_vector is
    begin return ncl_mux(sel(0), a, b); end function;

    function ncl_compare(a, b : ncl_logic_vector; op : string) return ncl_logic_vector is
        variable r    : ncl_logic_vector(0 downto 0);
        variable av, bv : std_logic_vector(a'range);
        variable cond : boolean;
    begin
        av := ncl_decode(a);
        bv := ncl_decode(b);
        if    op = ">"  then cond := unsigned(av) >  unsigned(bv);
        elsif op = "<"  then cond := unsigned(av) <  unsigned(bv);
        elsif op = ">=" then cond := unsigned(av) >= unsigned(bv);
        elsif op = "<=" then cond := unsigned(av) <= unsigned(bv);
        elsif op = "==" then cond := av = bv;
        elsif op = "!=" then cond := av /= bv;
        else cond := false;
        end if;
        if cond then r(0) := NCL_DATA1; else r(0) := NCL_DATA0; end if;
        return r;
    end function;

end package body ncl;
