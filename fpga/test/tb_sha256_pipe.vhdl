-- tb_sha256_pipe.vhdl — Test the 64-stage NCL SHA-256 pipeline.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity tb_sha256_pipe is end entity;

architecture test of tb_sha256_pipe is
    signal state_in  : ncl_logic_vector(255 downto 0);
    signal msg_in    : ncl_logic_vector(511 downto 0);
    signal state_out : ncl_logic_vector(255 downto 0);
    signal phase     : std_logic := '0';
    signal clr       : std_logic := '1';

    -- SHA-256 initial hash values H[0..7]
    constant H_INIT : std_logic_vector(255 downto 0) :=
        X"6a09e667" & X"bb67ae85" & X"3c6ef372" & X"a54ff53a" &
        X"510e527f" & X"9b05688c" & X"1f83d9ab" & X"5be0cd19";

    -- Pre-padded message block for "abc" (3 bytes)
    constant MSG_ABC : std_logic_vector(511 downto 0) :=
        X"61626380" & X"00000000" & X"00000000" & X"00000000" &
        X"00000000" & X"00000000" & X"00000000" & X"00000000" &
        X"00000000" & X"00000000" & X"00000000" & X"00000000" &
        X"00000000" & X"00000000" & X"00000000" & X"00000018";

    -- Expected compressed state (BEFORE adding H_INIT)
    -- The pipeline outputs the raw compression result; the caller
    -- adds H_INIT to get the final hash.
    -- SHA-256("abc") = ba7816bf 8f01cfea 414140de 5dae2223
    --                  b00361a3 96177a9c b410ff61 f20015ad
    constant HASH_ABC : std_logic_vector(255 downto 0) :=
        X"ba7816bf" & X"8f01cfea" & X"414140de" & X"5dae2223" &
        X"b00361a3" & X"96177a9c" & X"b410ff61" & X"f20015ad";

begin
    dut: entity work.e_sha256_pipeline(ncl_pipe)
        port map (
            state_in  => state_in,
            msg_in    => msg_in,
            state_out => state_out,
            phase     => phase,
            clr       => clr
        );

    stim: process
        variable result_bin : std_logic_vector(255 downto 0);
        variable h_init_w, result_w, final_w : unsigned(31 downto 0);
        variable final_hash : std_logic_vector(255 downto 0);

        procedure step is
        begin
            phase <= '1'; wait for 10 ns;
            phase <= '0'; wait for 10 ns;
        end procedure;
    begin
        -- Hold input constant
        state_in <= ncl_encode(H_INIT);
        msg_in   <= ncl_encode(MSG_ABC);

        wait for 1 ns;
        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;

        -- Push through 64 pipeline stages + 1 extra for output register
        for i in 1 to 65 loop
            step;
        end loop;

        -- Read and add H_INIT to get final hash
        result_bin := ncl_decode(state_out);
        for w in 0 to 7 loop
            h_init_w := unsigned(H_INIT((7-w)*32+31 downto (7-w)*32));
            result_w := unsigned(result_bin((7-w)*32+31 downto (7-w)*32));
            final_w  := h_init_w + result_w;
            final_hash((7-w)*32+31 downto (7-w)*32) :=
                std_logic_vector(final_w);
        end loop;

        report "Pipeline output (raw): 0x" & to_hstring(unsigned(result_bin));
        report "Final hash:            0x" & to_hstring(unsigned(final_hash));
        report "Expected:              0x" & to_hstring(unsigned(HASH_ABC));

        if final_hash = HASH_ABC then
            report "SHA-256 pipeline: PASS";
        else
            report "SHA-256 pipeline: FAIL" severity error;
        end if;

        wait;
    end process;
end architecture;
