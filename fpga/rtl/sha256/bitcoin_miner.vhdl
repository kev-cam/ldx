-- bitcoin_miner.vhdl — Bitcoin nonce iterator with SHA-256d pipeline.
--
-- Top-level entity that:
--   1. Takes a precomputed midstate and block2 template
--   2. Iterates nonce values (32-bit counter)
--   3. Splices nonce into block2 at word 3 (bits 415:384)
--   4. Feeds into SHA-256d pipeline
--   5. Checks output hash against difficulty target
--   6. Outputs found flag, winning nonce, and hash
--
-- The nonce is stored in Bitcoin's little-endian byte order within the
-- block header. When placed into the SHA-256 message word (big-endian),
-- the bytes are reversed. This entity handles the byte-swap internally:
-- it increments a native 32-bit counter, byte-swaps it, and places the
-- result at w[3] in the block2 message.
--
-- Latency: sha256d is 129 cycles (64 pipe1 + 1 pad_reg + 64 pipe2).
-- The miner registers the block2 input, adding 1 cycle, for 130 total.
-- Throughput: 1 nonce tested per phase cycle once pipeline is full.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity e_bitcoin_miner is
    generic (
        -- Number of leading zero bits required in the hash for a valid block.
        DIFFICULTY_ZEROS : natural := 32
    );
    port (
        -- Precomputed midstate (state after first 512-bit block of header)
        midstate        : in  ncl_logic_vector(255 downto 0);
        -- Block2 template: 512-bit second block with padding already applied.
        -- Word 3 (bits 415:384) is the nonce placeholder (will be overwritten).
        block2_template : in  ncl_logic_vector(511 downto 0);
        -- Starting nonce value (native 32-bit, will be byte-swapped for SHA)
        nonce_start     : in  std_logic_vector(31 downto 0);
        -- Control
        start           : in  std_logic;  -- pulse to begin mining
        -- Outputs
        found           : out std_logic;  -- asserted when valid nonce found
        nonce_out       : out std_logic_vector(31 downto 0);  -- winning nonce
        hash_out        : out ncl_logic_vector(255 downto 0);  -- winning hash
        -- Status
        running         : out std_logic;  -- high while mining
        nonces_tested   : out std_logic_vector(31 downto 0);  -- count
        -- Pipeline clock and reset
        phase           : in  std_logic;
        clr             : in  std_logic
    );
end entity;

architecture rtl of e_bitcoin_miner is

    -- SHA-256d pipeline latency:
    --   pipe1: 64 cycles (stage(0) combinational → stage(64) after 64 edges)
    --   midstate_delay: 64 cycles (aligned with pipe1)
    --   add+pad register: 1 cycle
    --   pipe2: 64 cycles
    --   final add: combinational
    -- Total: 64 + 1 + 64 = 129 cycles from sha256d input to output.
    --
    -- The miner registers sha_block2 on rising_edge, so add 1 cycle:
    -- Total from nonce_ctr → hash_out: 130 cycles.
    -- But: the miner starts feeding on the cycle AFTER start (signal delay),
    -- so we count from the first active cycle.
    --
    -- Use a shift register of valid bits to track pipeline fill.
    constant PIPE_DEPTH : natural := 130;

    -- SHA-256d instance signals
    signal sha_block2    : ncl_logic_vector(511 downto 0);
    signal sha_hash      : ncl_logic_vector(255 downto 0);

    -- Nonce counter
    signal nonce_ctr     : unsigned(31 downto 0);
    signal mining_active : std_logic := '0';
    signal found_i       : std_logic := '0';

    -- Nonce tracking: shift register to match pipeline latency.
    -- nonce_sr(0) = nonce being fed this cycle
    -- nonce_sr(PIPE_DEPTH-1) = nonce whose hash is at output now
    type nonce_sr_t is array (0 to PIPE_DEPTH-1) of unsigned(31 downto 0);
    signal nonce_sr : nonce_sr_t;

    -- Valid shift register: tracks when pipeline output corresponds to
    -- a real nonce (not pipeline fill garbage)
    signal valid_sr : std_logic_vector(0 to PIPE_DEPTH-1);

    -- Nonce count
    signal tested_count : unsigned(31 downto 0);

    -- Byte-swap: convert native u32 to little-endian byte order for SHA word
    function byte_swap(x : unsigned) return std_logic_vector is
        variable v : std_logic_vector(31 downto 0);
        variable r : std_logic_vector(31 downto 0);
    begin
        v := std_logic_vector(x);
        r(31 downto 24) := v(7 downto 0);
        r(23 downto 16) := v(15 downto 8);
        r(15 downto  8) := v(23 downto 16);
        r( 7 downto  0) := v(31 downto 24);
        return r;
    end function;

    -- Check difficulty: the hash in Bitcoin LE display must have leading zeros.
    -- In our big-endian word packing, the LE display reverses all 32 bytes,
    -- so LE leading zeros correspond to zeros at the LOW bits of our hash.
    -- Specifically: the last word h[7] (bits 31:0) reversed gives the first
    -- 4 bytes of the LE display. So we check from bit 0 upward.
    function meets_target(h : ncl_logic_vector; zeros : natural) return boolean is
        variable hv : std_logic_vector(255 downto 0);
    begin
        hv := ncl_decode(h);
        for i in 0 to zeros-1 loop
            if hv(i) /= '0' then
                return false;
            end if;
        end loop;
        return true;
    end function;

begin

    ---------------------------------------------------------------------------
    -- SHA-256d core
    ---------------------------------------------------------------------------
    u_sha256d: entity work.e_sha256d(ncl_pipe)
        port map (
            midstate   => midstate,
            block2_msg => sha_block2,
            hash_out   => sha_hash,
            phase      => phase,
            clr        => clr
        );

    ---------------------------------------------------------------------------
    -- Mining control process
    ---------------------------------------------------------------------------
    process(phase, clr)
        variable nonce_be : std_logic_vector(31 downto 0);
    begin
        if clr = '1' then
            nonce_ctr     <= (others => '0');
            mining_active <= '0';
            found_i       <= '0';
            sha_block2    <= (others => NCL_DATA0);
            nonce_sr      <= (others => (others => '0'));
            valid_sr      <= (others => '0');
            tested_count  <= (others => '0');
            nonce_out     <= (others => '0');
            hash_out      <= (others => NCL_DATA0);
            nonces_tested <= (others => '0');
        elsif rising_edge(phase) then

            -- Start mining on start pulse
            if start = '1' and mining_active = '0' then
                mining_active <= '1';
                nonce_ctr     <= unsigned(nonce_start);
                found_i       <= '0';
                valid_sr      <= (others => '0');
                tested_count  <= (others => '0');
            end if;

            -- Check output BEFORE shifting (valid_sr and nonce_sr still have
            -- previous cycle's values due to signal semantics — but we read
            -- the tail of the shift register which corresponds to the hash
            -- currently at sha_hash output).
            --
            -- Actually with VHDL signal semantics, all reads in this process
            -- see the values from BEFORE this rising_edge. sha_hash is
            -- combinational from pipe2 stage(64) which was registered on the
            -- PREVIOUS rising_edge. valid_sr(PIPE_DEPTH-1) indicates whether
            -- that hash corresponds to a real nonce.
            if valid_sr(PIPE_DEPTH-1) = '1' and found_i = '0' then
                tested_count <= tested_count + 1;
                nonces_tested <= std_logic_vector(tested_count + 1);

                if meets_target(sha_hash, DIFFICULTY_ZEROS) then
                    found_i   <= '1';
                    nonce_out <= std_logic_vector(nonce_sr(PIPE_DEPTH-1));
                    hash_out  <= sha_hash;
                end if;
            end if;

            -- Feed nonces into pipeline
            if mining_active = '1' and found_i = '0' then
                nonce_be := byte_swap(nonce_ctr);

                -- Splice nonce into block2 template
                sha_block2 <= block2_template;
                sha_block2(415 downto 384) <= ncl_encode(nonce_be);

                -- Shift registers
                nonce_sr(0) <= nonce_ctr;
                valid_sr(0) <= '1';
                for i in 1 to PIPE_DEPTH-1 loop
                    nonce_sr(i) <= nonce_sr(i-1);
                    valid_sr(i) <= valid_sr(i-1);
                end loop;

                nonce_ctr <= nonce_ctr + 1;
            end if;

        end if;
    end process;

    found   <= found_i;
    running <= mining_active and not found_i;

end architecture;
