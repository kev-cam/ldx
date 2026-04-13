-- bitcoin_miner_top.vhd — FPGA top for Bitcoin miner demo (DE2i-150).
--
-- Hardcoded for Bitcoin block #125552 test vector:
--   Midstate: 9524C59305C5671316E669BA2D2810A007E86E372F56A9DACD5BCE697A78DA2D
--   Block2 template: f1fc122b c7f5d74d f2b9441a 00000000 80000000 ...
--   Correct nonce: 0x9546A142
--
-- I/O:
--   clk_50  — 50 MHz board clock (drives pipeline phase)
--   led[0]  — blinks while running (toggles every 2^25 cycles)
--   led[1]  — solid ON when nonce found
--   led[2]  — solid ON while mining_active
--   led[3]  — heartbeat (toggles every 2^24 cycles)
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity bitcoin_miner_top is
    port (
        clk_50 : in  std_logic;
        led    : out std_logic_vector(3 downto 0)
    );
end entity;

architecture rtl of bitcoin_miner_top is

    -- Precomputed midstate for block #125552
    -- = SHA256_compress(H_INIT, BLOCK1) + H_INIT (word-by-word mod 2^32)
    -- Verified by simulation: found nonce 0x9546A142, hash has 64 leading zero bits.
    constant MIDSTATE : std_logic_vector(255 downto 0) :=
        X"9524C593" & X"05C56713" & X"16E669BA" & X"2D2810A0" &
        X"07E86E37" & X"2F56A9DA" & X"CD5BCE69" & X"7A78DA2D";

    -- Block 2 template for block #125552:
    --   w[0] = f1fc122b  (merkle root tail)
    --   w[1] = c7f5d74d  (timestamp)
    --   w[2] = f2b9441a  (bits/difficulty)
    --   w[3] = 00000000  (nonce placeholder — overwritten by miner)
    --   w[4] = 80000000  (SHA-256 padding)
    --   w[5..14] = 0
    --   w[15] = 00000280 (message length: 640 bits)
    constant BLOCK2_TEMPLATE : std_logic_vector(511 downto 0) :=
        X"f1fc122b" & X"c7f5d74d" & X"f2b9441a" & X"00000000" &
        X"80000000" & X"00000000" & X"00000000" & X"00000000" &
        X"00000000" & X"00000000" & X"00000000" & X"00000000" &
        X"00000000" & X"00000000" & X"00000000" & X"00000280";

    -- Block #125552 real difficulty target has 64 leading zero bits.
    -- Use DIFFICULTY_ZEROS = 32 for a quick FPGA demo (will find correct nonce
    -- and many near-miss nonces — first hit at 0x9546A142 anyway with full 64).
    constant DIFFICULTY_ZEROS : natural := 64;

    -- Start just below the known nonce for a fast demo
    constant START_NONCE : std_logic_vector(31 downto 0) := X"9546A13D";

    ---------------------------------------------------------------------------
    -- Internal signals
    ---------------------------------------------------------------------------
    signal phase   : std_logic;
    signal clr     : std_logic := '1';

    -- Reset counter (hold clr for 8 cycles after power-on)
    signal rst_cnt : unsigned(3 downto 0) := (others => '1');

    -- Start pulse (one cycle, issued after reset)
    signal start_r  : std_logic := '0';
    signal started  : std_logic := '0';

    -- Miner outputs
    signal found    : std_logic;
    signal running  : std_logic;
    signal nonce_out : std_logic_vector(31 downto 0);
    signal hash_out  : ncl_logic_vector(255 downto 0);
    signal nonces_tested : std_logic_vector(31 downto 0);

    -- Blink/heartbeat counters
    signal blink_cnt : unsigned(25 downto 0) := (others => '0');

begin

    phase <= clk_50;

    ---------------------------------------------------------------------------
    -- Power-on reset and auto-start
    ---------------------------------------------------------------------------
    process(clk_50)
    begin
        if rising_edge(clk_50) then
            if rst_cnt /= 0 then
                rst_cnt <= rst_cnt - 1;
                clr     <= '1';
                start_r <= '0';
            else
                clr <= '0';
                -- Issue one-cycle start pulse once after reset
                if started = '0' then
                    start_r <= '1';
                    started <= '1';
                else
                    start_r <= '0';
                end if;
            end if;

            blink_cnt <= blink_cnt + 1;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Bitcoin miner instance
    ---------------------------------------------------------------------------
    u_miner: entity work.e_bitcoin_miner(rtl)
        generic map (
            DIFFICULTY_ZEROS => DIFFICULTY_ZEROS
        )
        port map (
            midstate        => ncl_encode(MIDSTATE),
            block2_template => ncl_encode(BLOCK2_TEMPLATE),
            nonce_start     => START_NONCE,
            start           => start_r,
            found           => found,
            nonce_out       => nonce_out,
            hash_out        => hash_out,
            running         => running,
            nonces_tested   => nonces_tested,
            phase           => phase,
            clr             => clr
        );

    ---------------------------------------------------------------------------
    -- LED outputs
    --   led[0]: blink while running (stops when found)
    --   led[1]: solid ON when nonce found
    --   led[2]: solid ON while mining_active (running signal)
    --   led[3]: heartbeat (always toggling)
    ---------------------------------------------------------------------------
    led(0) <= blink_cnt(24) and running;
    led(1) <= found;
    led(2) <= running;
    led(3) <= blink_cnt(23);

end architecture;
