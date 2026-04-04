-- tb_ncl_blend.vhdl — Test NCL bitwise_blend: same function, async execution.
-- Verifies NCL version produces same results as synchronous RTL.
library IEEE;
use IEEE.std_logic_1164.all;
library async_ncl;
use async_ncl.ncl.all;

entity tb_ncl_blend is
end entity tb_ncl_blend;

architecture test of tb_ncl_blend is
    signal a, b, mask : ncl_logic_vector(63 downto 0);
    signal result     : ncl_logic_vector(63 downto 0);
    signal pass_count : integer := 0;
begin
    dut: entity work.bitwise_blend_ncl(ncl_comb)
        port map (a => a, b => b, mask => mask, result => result);

    stim: process
        procedure test_blend(
            av, bv, mv : std_logic_vector(63 downto 0);
            expected   : std_logic_vector(63 downto 0);
            msg        : string
        ) is
            variable got : std_logic_vector(63 downto 0);
        begin
            -- Data phase
            a <= ncl_encode(av);
            b <= ncl_encode(bv);
            mask <= ncl_encode(mv);
            wait for 10 ns;
            got := ncl_decode(result);
            assert got = expected
                report msg & ": FAIL" severity error;
            if got = expected then
                pass_count <= pass_count + 1;
                report msg & ": PASS";
            end if;
            -- NULL phase
            a <= (others => (L => '0', H => '0'));
            b <= (others => (L => '0', H => '0'));
            mask <= (others => (L => '0', H => '0'));
            wait for 10 ns;
        end procedure;
    begin
        a <= (others => (L => '0', H => '0'));
        b <= (others => (L => '0', H => '0'));
        mask <= (others => (L => '0', H => '0'));
        wait for 10 ns;

        -- blend(0xFF..FF, 0x00..00, 0xFF..FF) = 0xFF..FF (all from a)
        test_blend(X"FFFFFFFFFFFFFFFF", X"0000000000000000", X"FFFFFFFFFFFFFFFF",
                   X"FFFFFFFFFFFFFFFF", "all-a");

        -- blend(0xFF..FF, 0x00..00, 0x00..00) = 0x00..00 (all from b)
        test_blend(X"FFFFFFFFFFFFFFFF", X"0000000000000000", X"0000000000000000",
                   X"0000000000000000", "all-b");

        -- blend(0xDEAD, 0xBEEF, 0xFF00) = 0xDEEF
        test_blend(X"000000000000DEAD", X"000000000000BEEF", X"000000000000FF00",
                   X"000000000000DEEF", "DEAD/BEEF");

        -- blend(0xCAFE, 0xBABE, 0xF0F0) = 0xCABE
        test_blend(X"000000000000CAFE", X"000000000000BABE", X"000000000000F0F0",
                   X"000000000000CAFE", "CAFE/BABE");

        report "NCL BITWISE_BLEND: " & integer'image(pass_count) & " of 4 passed";
        wait;
    end process;
end architecture test;
