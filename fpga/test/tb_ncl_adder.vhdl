-- tb_ncl_adder.vhdl — Test NCL async 1-bit full adder from ARV.
library IEEE;
use IEEE.std_logic_1164.all;
library async_ncl;
use async_ncl.ncl.all;

entity tb_ncl_adder is
end entity tb_ncl_adder;

architecture test of tb_ncl_adder is
    signal a, b, cin  : ncl_logic;
    signal s, cout    : ncl_logic;
    signal pass_count : integer := 0;
begin
    dut: entity work.binary_adder_ncl_entity(binary_adder_ncl_fulladder_arch)
        port map (A => a, B => b, Cin => cin, S => s, Cout => cout);

    stim: process
        procedure test_add(
            av, bv, cv : std_logic;
            es, ec     : std_logic;
            msg        : string
        ) is
        begin
            -- Data phase
            a <= ncl_encode(av);
            b <= ncl_encode(bv);
            cin <= ncl_encode(cv);
            wait for 10 ns;
            assert ncl_decode(s) = es and ncl_decode(cout) = ec
                report msg & ": FAIL (s=" & std_logic'image(ncl_decode(s))
                     & " cout=" & std_logic'image(ncl_decode(cout)) & ")"
                severity error;
            if ncl_decode(s) = es and ncl_decode(cout) = ec then
                pass_count <= pass_count + 1;
                report msg & ": PASS";
            end if;
            -- NULL phase (spacer)
            a <= (L => '0', H => '0');
            b <= (L => '0', H => '0');
            cin <= (L => '0', H => '0');
            wait for 10 ns;
        end procedure;
    begin
        -- Start NULL
        a <= (L => '0', H => '0');
        b <= (L => '0', H => '0');
        cin <= (L => '0', H => '0');
        wait for 10 ns;

        -- Truth table for 1-bit full adder
        test_add('0', '0', '0', '0', '0', "0+0+0=00");
        test_add('0', '0', '1', '1', '0', "0+0+1=01");
        test_add('0', '1', '0', '1', '0', "0+1+0=01");
        test_add('0', '1', '1', '0', '1', "0+1+1=10");
        test_add('1', '0', '0', '1', '0', "1+0+0=01");
        test_add('1', '0', '1', '0', '1', "1+0+1=10");
        test_add('1', '1', '0', '0', '1', "1+1+0=10");
        test_add('1', '1', '1', '1', '1', "1+1+1=11");

        report "NCL ADDER: " & integer'image(pass_count) & " of 8 passed";
        wait;
    end process;
end architecture test;
