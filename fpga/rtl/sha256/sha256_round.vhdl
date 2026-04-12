-- sha256_round.vhdl — One round of SHA-256 compression in NCL.
--
-- Pure combinational: no registers, no clock. The NCL NULL/DATA
-- wavefront propagates through naturally. Rotation is zero gates
-- (wire permutation on dual-rail pairs).
--
-- Compiles against both ncl libraries:
--   lib/ncl/      → true dual-rail with NULL wavefronts (simulation/ASIC)
--   lib/ncl_sync/ → single-rail binary (FPGA synthesis)
library IEEE;
use IEEE.std_logic_1164.all;
library ncl;
use ncl.ncl.all;

entity e_sha256_round is
    port (
        -- Input state
        a_in, b_in, c_in, d_in : in  ncl_logic_vector(31 downto 0);
        e_in, f_in, g_in, h_in : in  ncl_logic_vector(31 downto 0);
        -- Round constant K[i] and message schedule word w[i]
        k_i  : in  ncl_logic_vector(31 downto 0);
        w_i  : in  ncl_logic_vector(31 downto 0);
        -- Output state
        a_out, b_out, c_out, d_out : out ncl_logic_vector(31 downto 0);
        e_out, f_out, g_out, h_out : out ncl_logic_vector(31 downto 0)
    );
end entity;

architecture ncl_comb of e_sha256_round is
    -- Rotate right: just wire permutation — zero gates in NCL!
    function rotr(x : ncl_logic_vector; n : natural)
        return ncl_logic_vector is
        variable r : ncl_logic_vector(31 downto 0);
    begin
        for i in 31 downto 0 loop
            r(i) := x((i + n) mod 32);
        end loop;
        return r;
    end function;

    -- Shift right: low bits get DATA0
    function shr(x : ncl_logic_vector; n : natural)
        return ncl_logic_vector is
        variable r : ncl_logic_vector(31 downto 0);
    begin
        r := (others => NCL_DATA0);
        for i in 31 downto n loop
            r(i - n) := x(i);
        end loop;
        return r;
    end function;

    signal sigma1_e, ch_efg, t1 : ncl_logic_vector(31 downto 0);
    signal sigma0_a, maj_abc, t2 : ncl_logic_vector(31 downto 0);
    signal t1_plus_t2 : ncl_logic_vector(31 downto 0);
    signal d_plus_t1  : ncl_logic_vector(31 downto 0);

    -- Intermediate additions for t1: h + Σ1 + Ch + K + w
    signal h_plus_s1     : ncl_logic_vector(31 downto 0);
    signal h_s1_ch       : ncl_logic_vector(31 downto 0);
    signal h_s1_ch_k     : ncl_logic_vector(31 downto 0);
begin
    -- Σ1(e) = rotr(e,6) ⊕ rotr(e,11) ⊕ rotr(e,25)
    sigma1_e <= rotr(e_in, 6) xor rotr(e_in, 11) xor rotr(e_in, 25);

    -- Ch(e,f,g) = (e & f) ⊕ (~e & g)
    ch_efg <= (e_in and f_in) xor ((not e_in) and g_in);

    -- t1 = h + Σ1(e) + Ch(e,f,g) + K[i] + w[i]
    h_plus_s1 <= ncl_add(h_in, sigma1_e);
    h_s1_ch   <= ncl_add(h_plus_s1, ch_efg);
    h_s1_ch_k <= ncl_add(h_s1_ch, k_i);
    t1        <= ncl_add(h_s1_ch_k, w_i);

    -- Σ0(a) = rotr(a,2) ⊕ rotr(a,13) ⊕ rotr(a,22)
    sigma0_a <= rotr(a_in, 2) xor rotr(a_in, 13) xor rotr(a_in, 22);

    -- Maj(a,b,c) = (a & b) ⊕ (a & c) ⊕ (b & c)
    maj_abc <= (a_in and b_in) xor (a_in and c_in) xor (b_in and c_in);

    -- t2 = Σ0(a) + Maj(a,b,c)
    t2 <= ncl_add(sigma0_a, maj_abc);

    -- New state
    d_plus_t1  <= ncl_add(d_in, t1);
    t1_plus_t2 <= ncl_add(t1, t2);

    a_out <= t1_plus_t2;
    b_out <= a_in;
    c_out <= b_in;
    d_out <= c_in;
    e_out <= d_plus_t1;
    f_out <= e_in;
    g_out <= f_in;
    h_out <= g_in;
end architecture;
