-- sha256_w_expand.vhdl — Message schedule expansion for one pipeline stage.
--
-- Takes the 16-word sliding window ws[0..15] and produces:
--   current_w = ws[0]  (used by the round function this stage)
--   ws_out[0..15] = {ws[1..15], new_w}  (shifted window for next stage)
--   new_w = σ1(ws[14]) + ws[9] + σ0(ws[1]) + ws[0]
--
-- This is purely combinational. Rotations are zero-cost wire
-- permutations in NCL.
library IEEE;
use IEEE.std_logic_1164.all;
library ncl;
use ncl.ncl.all;

entity e_sha256_w_expand is
    port (
        ws_in   : in  ncl_logic_vector(511 downto 0);  -- 16 × 32 bits
        w_out   : out ncl_logic_vector(31 downto 0);    -- current round's w
        ws_out  : out ncl_logic_vector(511 downto 0)     -- shifted window
    );
end entity;

architecture ncl_comb of e_sha256_w_expand is
    function rotr(x : ncl_logic_vector; n : natural)
        return ncl_logic_vector is
        variable r : ncl_logic_vector(31 downto 0);
    begin
        for i in 31 downto 0 loop
            r(i) := x((i + n) mod 32);
        end loop;
        return r;
    end function;

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

    -- Extract word i from the 512-bit bus (word 0 = bits 31..0)
    -- Word 0 is at the MSB end: ws(511:480) = w[0], ws(31:0) = w[15]
    function get_w(ws : ncl_logic_vector; i : natural)
        return ncl_logic_vector is
        variable r : ncl_logic_vector(31 downto 0);
        constant base : natural := (15 - i) * 32;
    begin
        for b in 0 to 31 loop
            r(b) := ws(base + b);
        end loop;
        return r;
    end function;

    signal sig0_w1  : ncl_logic_vector(31 downto 0);
    signal sig1_w14 : ncl_logic_vector(31 downto 0);
    signal new_w    : ncl_logic_vector(31 downto 0);
    signal sum1, sum2 : ncl_logic_vector(31 downto 0);
begin
    -- Current round uses ws[0]
    w_out <= get_w(ws_in, 0);

    -- σ0(ws[1]) = rotr(ws[1],7) ⊕ rotr(ws[1],18) ⊕ shr(ws[1],3)
    sig0_w1 <= rotr(get_w(ws_in, 1), 7)
           xor rotr(get_w(ws_in, 1), 18)
           xor shr(get_w(ws_in, 1), 3);

    -- σ1(ws[14]) = rotr(ws[14],17) ⊕ rotr(ws[14],19) ⊕ shr(ws[14],10)
    sig1_w14 <= rotr(get_w(ws_in, 14), 17)
            xor rotr(get_w(ws_in, 14), 19)
            xor shr(get_w(ws_in, 14), 10);

    -- new_w = σ1(ws[14]) + ws[9] + σ0(ws[1]) + ws[0]
    sum1  <= ncl_add(sig1_w14, get_w(ws_in, 9));
    sum2  <= ncl_add(sig0_w1, get_w(ws_in, 0));
    new_w <= ncl_add(sum1, sum2);

    -- Shift window: drop oldest (w[0]), append newest (new_w)
    -- ws_out[0] = ws_in[1], ws_out[1] = ws_in[2], ..., ws_out[14] = ws_in[15], ws_out[15] = new_w
    -- In MSB-first packing: ws_out(511:480) = ws_in[1], ..., ws_out(31:0) = new_w
    shift_gen: for i in 0 to 14 generate
        ws_out((15-i)*32+31 downto (15-i)*32) <= get_w(ws_in, i+1);
    end generate;
    ws_out(31 downto 0) <= new_w;
end architecture;
