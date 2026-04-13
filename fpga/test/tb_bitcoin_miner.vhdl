-- tb_bitcoin_miner.vhdl — Testbench for Bitcoin miner using block #125552.
--
-- Bitcoin block #125552:
--   Header (80 bytes): version + prev_hash + merkle_root + time + bits + nonce
--   Known nonce: 0x9546a142 (LE bytes in header: 42 a1 46 95)
--   Expected double-SHA-256 (LE display):
--     00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d
--
-- Test strategy:
--   1. Use a pipeline instance to compute the midstate from block 1
--   2. Feed the midstate and block2 template to e_bitcoin_miner
--   3. Start from nonce-5, expect it to find the correct nonce after 5 iterations
--   4. Verify the hash has sufficient leading zeros
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity tb_bitcoin_miner is end entity;

architecture test of tb_bitcoin_miner is

    -- SHA-256 initial hash values
    constant H_INIT : std_logic_vector(255 downto 0) :=
        X"6a09e667" & X"bb67ae85" & X"3c6ef372" & X"a54ff53a" &
        X"510e527f" & X"9b05688c" & X"1f83d9ab" & X"5be0cd19";

    -- Bitcoin block #125552 header (80 bytes)
    -- Block 1: first 64 bytes (512 bits)
    constant BLOCK1 : std_logic_vector(511 downto 0) :=
        X"01000000" &  -- version
        X"81cd02ab" & X"7e569e8b" & X"cd9317e2" & X"fe99f2de" &  -- prev_hash
        X"44d49ab2" & X"b8851ba4" & X"a3080000" & X"00000000" &
        X"e320b6c2" & X"fffc8d75" & X"0423db8b" & X"1eb942ae" &  -- merkle_root (partial)
        X"710e951e" & X"d797f7af" & X"fc8892b0";

    -- Block 2 data: bytes 64-79 of header (16 bytes = 4 words)
    -- w[0] = f1fc122b (merkle_root tail)
    -- w[1] = c7f5d74d (timestamp)
    -- w[2] = f2b9441a (bits/difficulty)
    -- w[3] = 42a14695 (nonce - will be overwritten by miner)
    -- + SHA-256 padding for 80-byte message (640 bits)
    constant BLOCK2_TEMPLATE : std_logic_vector(511 downto 0) :=
        X"f1fc122b" &  -- w[0]: merkle root tail
        X"c7f5d74d" &  -- w[1]: timestamp
        X"f2b9441a" &  -- w[2]: bits
        X"00000000" &  -- w[3]: nonce placeholder
        X"80000000" &  -- w[4]: padding start (0x80 byte)
        X"00000000" &  -- w[5]
        X"00000000" &  -- w[6]
        X"00000000" &  -- w[7]
        X"00000000" &  -- w[8]
        X"00000000" &  -- w[9]
        X"00000000" &  -- w[10]
        X"00000000" &  -- w[11]
        X"00000000" &  -- w[12]
        X"00000000" &  -- w[13]
        X"00000000" &  -- w[14]
        X"00000280";   -- w[15]: length = 640 bits

    -- Known correct nonce (native 32-bit value, little-endian in header)
    -- Header bytes at offset 76: 42 a1 46 95
    -- As little-endian u32: 0x9546a142
    constant CORRECT_NONCE : std_logic_vector(31 downto 0) := X"9546a142";

    -- Start 5 before the correct nonce
    constant START_NONCE : std_logic_vector(31 downto 0) := X"9546a13d";

    -- Difficulty: block 125552 hash has 64 trailing zero bits (in BE packing).
    -- That corresponds to 8 leading zero bytes in Bitcoin LE display.
    -- Check all 64 to avoid false positives from nearby nonces.
    constant DIFFICULTY : natural := 64;

    -- Expected double-SHA-256 in big-endian word order
    -- (LE display: 00000000000000001e8d6829a8a21adc5d38d0a473b144b6765798e61f98bd1d)
    constant EXPECTED_HASH_LE : std_logic_vector(255 downto 0) :=
        X"00000000" & X"00000000" & X"1e8d6829" & X"a8a21adc" &
        X"5d38d0a4" & X"73b144b6" & X"765798e6" & X"1f98bd1d";

    -- Signals for midstate computation pipeline
    signal mid_state_in  : ncl_logic_vector(255 downto 0);
    signal mid_msg_in    : ncl_logic_vector(511 downto 0);
    signal mid_state_out : ncl_logic_vector(255 downto 0);

    -- Signals for bitcoin miner
    signal midstate_ncl   : ncl_logic_vector(255 downto 0);
    signal block2_ncl     : ncl_logic_vector(511 downto 0);
    signal miner_hash     : ncl_logic_vector(255 downto 0);
    signal miner_found    : std_logic;
    signal miner_nonce    : std_logic_vector(31 downto 0);
    signal miner_running  : std_logic;
    signal miner_tested   : std_logic_vector(31 downto 0);
    signal miner_start    : std_logic := '0';

    signal phase : std_logic := '0';
    signal clr   : std_logic := '1';

    -- Midstate computation result (binary)
    signal midstate_bin : std_logic_vector(255 downto 0);

begin

    ---------------------------------------------------------------------------
    -- Pipeline for midstate computation: compress(H_INIT, block1)
    ---------------------------------------------------------------------------
    u_midstate_pipe: entity work.e_sha256_pipeline(ncl_pipe)
        port map (
            state_in  => mid_state_in,
            msg_in    => mid_msg_in,
            state_out => mid_state_out,
            phase     => phase,
            clr       => clr
        );

    ---------------------------------------------------------------------------
    -- Bitcoin miner under test
    ---------------------------------------------------------------------------
    u_miner: entity work.e_bitcoin_miner(rtl)
        generic map (
            DIFFICULTY_ZEROS => DIFFICULTY
        )
        port map (
            midstate        => midstate_ncl,
            block2_template => block2_ncl,
            nonce_start     => START_NONCE,
            start           => miner_start,
            found           => miner_found,
            nonce_out       => miner_nonce,
            hash_out        => miner_hash,
            running         => miner_running,
            nonces_tested   => miner_tested,
            phase           => phase,
            clr             => clr
        );

    ---------------------------------------------------------------------------
    -- Stimulus process
    ---------------------------------------------------------------------------
    stim: process
        variable raw_bin      : std_logic_vector(255 downto 0);
        variable h_init_w     : unsigned(31 downto 0);
        variable result_w     : unsigned(31 downto 0);
        variable final_w      : unsigned(31 downto 0);
        variable hash_bin     : std_logic_vector(255 downto 0);
        variable hash_le      : std_logic_vector(255 downto 0);

        procedure step is
        begin
            phase <= '1'; wait for 10 ns;
            phase <= '0'; wait for 10 ns;
        end procedure;
    begin
        report "=== Bitcoin Miner Testbench (Block #125552) ===";

        -----------------------------------------------------------------
        -- Phase 1: Compute midstate from block 1
        -----------------------------------------------------------------
        report "Phase 1: Computing midstate from block 1...";

        mid_state_in <= ncl_encode(H_INIT);
        mid_msg_in   <= ncl_encode(BLOCK1);

        -- Reset
        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;

        -- Clock 65 cycles (64 stages + 1 for output register)
        for i in 1 to 65 loop
            step;
        end loop;

        -- Read raw output and add H_INIT to get midstate
        raw_bin := ncl_decode(mid_state_out);
        for w in 0 to 7 loop
            h_init_w := unsigned(H_INIT((7-w)*32+31 downto (7-w)*32));
            result_w := unsigned(raw_bin((7-w)*32+31 downto (7-w)*32));
            final_w  := h_init_w + result_w;
            midstate_bin((7-w)*32+31 downto (7-w)*32) <=
                std_logic_vector(final_w);
        end loop;

        wait for 1 ns;  -- let signal propagate

        report "Midstate: 0x" & to_hstring(unsigned(midstate_bin));

        -----------------------------------------------------------------
        -- Phase 2: Start the Bitcoin miner
        -----------------------------------------------------------------
        report "Phase 2: Starting Bitcoin miner from nonce 0x" &
               to_hstring(unsigned(START_NONCE)) & "...";

        -- Set midstate and block2 template for the miner
        midstate_ncl <= ncl_encode(midstate_bin);
        block2_ncl   <= ncl_encode(BLOCK2_TEMPLATE);

        -- Reset everything
        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;

        -- Start mining
        miner_start <= '1';
        step;
        miner_start <= '0';

        -- Run until found or timeout (500 cycles should be more than enough:
        -- pipeline latency ~130 + 5 nonces to test)
        for i in 1 to 500 loop
            step;
            if miner_found = '1' then
                report "Found nonce after " & integer'image(i) & " cycles!";
                exit;
            end if;
        end loop;

        -----------------------------------------------------------------
        -- Phase 3: Check results
        -----------------------------------------------------------------
        if miner_found = '1' then
            report "Winning nonce: 0x" & to_hstring(unsigned(miner_nonce));
            report "Expected:      0x" & to_hstring(unsigned(CORRECT_NONCE));

            hash_bin := ncl_decode(miner_hash);
            report "Hash (BE): 0x" & to_hstring(unsigned(hash_bin));

            -- Reverse bytes for Bitcoin LE display
            for i in 0 to 31 loop
                hash_le(i*8+7 downto i*8) := hash_bin((31-i)*8+7 downto (31-i)*8);
            end loop;
            report "Hash (LE): 0x" & to_hstring(unsigned(hash_le));

            report "Expected (LE): 0x" & to_hstring(unsigned(EXPECTED_HASH_LE));
            report "Nonces tested: " &
                   integer'image(to_integer(unsigned(miner_tested)));

            if miner_nonce = CORRECT_NONCE then
                report "PASS: Correct nonce found!";
            else
                report "FAIL: Wrong nonce!" severity error;
            end if;
        else
            report "FAIL: Nonce not found within timeout!" severity error;
        end if;

        report "=== Test complete ===";
        wait;
    end process;

end architecture;
