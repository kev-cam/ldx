-- sha256d.vhdl — Double SHA-256 for Bitcoin mining (NCL pipeline).
--
-- Performs SHA-256(SHA-256(block)) using the midstate optimization:
--   - Pipeline 1: compress(midstate, block2)  → first_hash
--   - Pipeline 2: compress(H_INIT, pad(first_hash)) → double_hash
--
-- The midstate (state after first 512-bit block) is precomputed externally
-- since it doesn't change when the nonce varies.
--
-- Inputs:
--   midstate    : 256-bit state after compressing block 1 with H_INIT
--   block2_msg  : 512-bit second block (bytes 64-79 + SHA-256 padding)
--                 Nonce is at word 3 (bits 415:384 in MSB-first packing)
--
-- Output:
--   hash_out    : 256-bit final double-hash result
--   hash_valid  : pulse when hash_out is valid (128 cycles after input)
--
-- Latency: 128+1 phase cycles (64 for each pipeline + 1 for add/pad reg).
-- Throughput: 1 hash per phase cycle once filled.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity e_sha256d is
    port (
        -- Precomputed midstate from first block
        midstate    : in  ncl_logic_vector(255 downto 0);
        -- Second 512-bit block (with nonce + padding)
        block2_msg  : in  ncl_logic_vector(511 downto 0);
        -- Double-hash output
        hash_out    : out ncl_logic_vector(255 downto 0);
        -- Debug
        dbg_first_hash : out ncl_logic_vector(255 downto 0);
        dbg_second_block : out ncl_logic_vector(511 downto 0);
        -- Pipeline clock and reset
        phase       : in  std_logic;
        clr         : in  std_logic
    );
end entity;

architecture ncl_pipe of e_sha256d is

    -- SHA-256 initial hash values
    constant H_INIT : std_logic_vector(255 downto 0) :=
        X"6a09e667" & X"bb67ae85" & X"3c6ef372" & X"a54ff53a" &
        X"510e527f" & X"9b05688c" & X"1f83d9ab" & X"5be0cd19";

    -- Pipeline 1 output (raw compression, before adding midstate)
    signal pipe1_raw : ncl_logic_vector(255 downto 0);

    -- First hash = midstate + pipe1_raw (word-by-word mod 2^32)
    signal first_hash : ncl_logic_vector(255 downto 0);

    -- Registered first hash + padding for second SHA-256
    signal second_block : ncl_logic_vector(511 downto 0);

    -- Registered midstate for the addition (needs to be delayed 64 cycles
    -- to align with pipe1_raw output from the pipeline)
    type midstate_delay_t is array (0 to 64) of ncl_logic_vector(255 downto 0);
    signal midstate_dly : midstate_delay_t;

    -- Pipeline 2 output
    signal pipe2_raw : ncl_logic_vector(255 downto 0);

    -- H_INIT as NCL (constant, registered once)
    signal h_init_ncl : ncl_logic_vector(255 downto 0);

    -- Helper: add two 256-bit vectors word-by-word (8 x 32-bit additions)
    function get_word(v : ncl_logic_vector; i : natural)
        return ncl_logic_vector is
        variable r : ncl_logic_vector(31 downto 0);
        constant base : natural := (7 - i) * 32;
    begin
        for b in 0 to 31 loop r(b) := v(base + b); end loop;
        return r;
    end function;

    procedure set_word(signal v : inout ncl_logic_vector;
                       i : natural; w : ncl_logic_vector) is
    begin
        for b in 0 to 31 loop v((7-i)*32 + b) <= w(b); end loop;
    end procedure;

    function add_state(a, b : ncl_logic_vector) return ncl_logic_vector is
        variable r : ncl_logic_vector(255 downto 0);
        variable wa, wb, wr : ncl_logic_vector(31 downto 0);
    begin
        for w in 0 to 7 loop
            wa := get_word(a, w);
            wb := get_word(b, w);
            wr := ncl_add(wa, wb);
            for bt in 0 to 31 loop r((7-w)*32 + bt) := wr(bt); end loop;
        end loop;
        return r;
    end function;

    -- Build the padded second-hash block from first_hash (32 bytes):
    -- first_hash (256 bits) | 0x80000000 | zeros(6 words) | 0x00000100
    -- Total: 8 + 1 + 6 + 1 = 16 words = 512 bits
    -- Length field: 256 bits = 0x100, stored as 64-bit BE at end
    function pad_second_block(h : ncl_logic_vector) return ncl_logic_vector is
        variable blk : ncl_logic_vector(511 downto 0);
        variable w8  : ncl_logic_vector(31 downto 0) := ncl_encode(X"80000000");
        variable w15 : ncl_logic_vector(31 downto 0) := ncl_encode(X"00000100");
    begin
        -- Words 0-7: the first hash (256 bits) at MSB end
        for b in 0 to 255 loop blk(256 + b) := h(b); end loop;
        -- Word 8 at bits 255:224 (position (15-8)*32 = 224)
        for b in 0 to 31 loop blk((15-8)*32 + b) := w8(b); end loop;
        -- Words 9-14: zeros
        for w in 9 to 14 loop
            for b in 0 to 31 loop blk((15-w)*32 + b) := NCL_DATA0; end loop;
        end loop;
        -- Word 15 at bits 31:0 (position (15-15)*32 = 0)
        for b in 0 to 31 loop blk(b) := w15(b); end loop;
        return blk;
    end function;

begin
    -- Constant encoding of H_INIT
    h_init_ncl <= ncl_encode(H_INIT);

    ---------------------------------------------------------------------------
    -- Pipeline 1: compress(midstate, block2_msg)
    ---------------------------------------------------------------------------
    u_pipe1: entity work.e_sha256_pipeline(ncl_pipe)
        port map (
            state_in  => midstate,
            msg_in    => block2_msg,
            state_out => pipe1_raw,
            phase     => phase,
            clr       => clr
        );

    ---------------------------------------------------------------------------
    -- Delay midstate by 64 cycles to align with pipe1 output
    ---------------------------------------------------------------------------
    midstate_dly(0) <= midstate;
    gen_mid_dly: for i in 0 to 63 generate
        process(phase, clr)
        begin
            if clr = '1' then
                midstate_dly(i+1) <= (others => NCL_DATA0);
            elsif rising_edge(phase) then
                midstate_dly(i+1) <= midstate_dly(i);
            end if;
        end process;
    end generate;

    ---------------------------------------------------------------------------
    -- Add midstate to raw compression output → first_hash
    -- Both pipe1_raw and midstate_dly(64) are 64 cycles delayed from input
    ---------------------------------------------------------------------------
    first_hash <= add_state(pipe1_raw, midstate_dly(64));

    ---------------------------------------------------------------------------
    -- Register the padded second block (adds 1 cycle latency)
    ---------------------------------------------------------------------------
    process(phase, clr)
    begin
        if clr = '1' then
            second_block <= (others => NCL_DATA0);
        elsif rising_edge(phase) then
            second_block <= pad_second_block(first_hash);
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Pipeline 2: compress(H_INIT, padded_first_hash)
    ---------------------------------------------------------------------------
    u_pipe2: entity work.e_sha256_pipeline(ncl_pipe)
        port map (
            state_in  => h_init_ncl,
            msg_in    => second_block,
            state_out => pipe2_raw,
            phase     => phase,
            clr       => clr
        );

    ---------------------------------------------------------------------------
    -- Final hash = H_INIT + pipe2_raw
    ---------------------------------------------------------------------------
    hash_out <= add_state(pipe2_raw, h_init_ncl);
    dbg_first_hash <= first_hash;
    dbg_second_block <= second_block;

end architecture;
