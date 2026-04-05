-- tb_ncl_arith.vhdl — Test NCL add and max: verify async == sync results.
library IEEE;
use IEEE.std_logic_1164.all;
library async_ncl;
use async_ncl.ncl.all;

entity tb_ncl_arith is
end entity tb_ncl_arith;

architecture test of tb_ncl_arith is
    -- add
    signal add_a, add_b, add_r : ncl_logic_vector(31 downto 0);
    -- max
    signal max_a, max_b, max_r : ncl_logic_vector(31 downto 0);
    signal pass_count : integer := 0;
    signal fail_count : integer := 0;
begin
    u_add: entity work.add_ncl(ncl_comb)
        port map (a => add_a, b => add_b, result => add_r);
    u_max: entity work.max_ncl(ncl_comb)
        port map (a => max_a, b => max_b, result => max_r);

    stim: process
        procedure check(got, expected : std_logic_vector; msg : string) is
        begin
            if got = expected then
                pass_count <= pass_count + 1;
                report msg & ": PASS";
            else
                fail_count <= fail_count + 1;
                report msg & ": FAIL" severity error;
            end if;
        end procedure;

        procedure null_phase is
        begin
            add_a <= (others => NCL_NULL); add_b <= (others => NCL_NULL);
            max_a <= (others => NCL_NULL); max_b <= (others => NCL_NULL);
            wait for 10 ns;
        end procedure;
    begin
        null_phase;

        -- Test add(42, 58) = 100
        add_a <= ncl_encode(X"0000002A"); add_b <= ncl_encode(X"0000003A");
        max_a <= (others => NCL_NULL); max_b <= (others => NCL_NULL);
        wait for 10 ns;
        check(ncl_decode(add_r), X"00000064", "add(42,58)=100");
        null_phase;

        -- Test add(0xFFFFFFFF, 1) = 0 (overflow wrap)
        add_a <= ncl_encode(X"FFFFFFFF"); add_b <= ncl_encode(X"00000001");
        wait for 10 ns;
        check(ncl_decode(add_r), X"00000000", "add(FFFFFFFF,1)=0");
        null_phase;

        -- Test add(100, 200) = 300
        add_a <= ncl_encode(X"00000064"); add_b <= ncl_encode(X"000000C8");
        wait for 10 ns;
        check(ncl_decode(add_r), X"0000012C", "add(100,200)=300");
        null_phase;

        -- Test max(42, 58) = 58
        max_a <= ncl_encode(X"0000002A"); max_b <= ncl_encode(X"0000003A");
        add_a <= (others => NCL_NULL); add_b <= (others => NCL_NULL);
        wait for 10 ns;
        check(ncl_decode(max_r), X"0000003A", "max(42,58)=58");
        null_phase;

        -- Test max(100, 50) = 100
        max_a <= ncl_encode(X"00000064"); max_b <= ncl_encode(X"00000032");
        wait for 10 ns;
        check(ncl_decode(max_r), X"00000064", "max(100,50)=100");
        null_phase;

        -- Test max(7, 7) = 7
        max_a <= ncl_encode(X"00000007"); max_b <= ncl_encode(X"00000007");
        wait for 10 ns;
        check(ncl_decode(max_r), X"00000007", "max(7,7)=7");
        null_phase;

        report "NCL ARITH: " & integer'image(pass_count) & " passed, "
             & integer'image(fail_count) & " failed";
        if fail_count = 0 then
            report "ALL PASS";
        end if;
        wait;
    end process;
end architecture test;
