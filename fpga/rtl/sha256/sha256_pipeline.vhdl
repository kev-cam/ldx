-- sha256_pipeline.vhdl — 64-stage pipelined SHA-256 in NCL.
--
-- Each stage: combinational round + w_expand, separated by NCL
-- pipeline registers. In the ncl_sync build (FPGA), the registers
-- are ordinary FFs driven by `phase`. In a true NCL build (ASIC),
-- they would be completion-detected latches.
--
-- Input:  256-bit initial state (H[0..7]) + 512-bit message block
-- Output: 256-bit final state (hash result)
--
-- Latency: 64 phase cycles to fill the pipeline.
-- Throughput: 1 hash per phase cycle once filled.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity e_sha256_pipeline is
    port (
        -- Input: initial hash state + message block
        state_in : in  ncl_logic_vector(255 downto 0);  -- a,b,c,d,e,f,g,h
        msg_in   : in  ncl_logic_vector(511 downto 0);  -- w[0..15]
        -- Output: final hash state
        state_out: out ncl_logic_vector(255 downto 0);
        -- Pipeline clock (FPGA: phase; ASIC: replaced by NCL handshake)
        phase    : in  std_logic;
        clr      : in  std_logic
    );
end entity;

architecture ncl_pipe of e_sha256_pipeline is

    -- SHA-256 round constants K[0..63]
    type k_array_t is array (0 to 63) of std_logic_vector(31 downto 0);
    constant K : k_array_t := (
        X"428a2f98", X"71374491", X"b5c0fbcf", X"e9b5dba5",
        X"3956c25b", X"59f111f1", X"923f82a4", X"ab1c5ed5",
        X"d807aa98", X"12835b01", X"243185be", X"550c7dc3",
        X"72be5d74", X"80deb1fe", X"9bdc06a7", X"c19bf174",
        X"e49b69c1", X"efbe4786", X"0fc19dc6", X"240ca1cc",
        X"2de92c6f", X"4a7484aa", X"5cb0a9dc", X"76f988da",
        X"983e5152", X"a831c66d", X"b00327c8", X"bf597fc7",
        X"c6e00bf3", X"d5a79147", X"06ca6351", X"14292967",
        X"27b70a85", X"2e1b2138", X"4d2c6dfc", X"53380d13",
        X"650a7354", X"766a0abb", X"81c2c92e", X"92722c85",
        X"a2bfe8a1", X"a81a664b", X"c24b8b70", X"c76c51a3",
        X"d192e819", X"d6990624", X"f40e3585", X"106aa070",
        X"19a4c116", X"1e376c08", X"2748774c", X"34b0bcb5",
        X"391c0cb3", X"4ed8aa4a", X"5b9cca4f", X"682e6ff3",
        X"748f82ee", X"78a5636f", X"84c87814", X"8cc70208",
        X"90befffa", X"a4506ceb", X"bef9a3f7", X"c67178f2"
    );

    -- Pipeline bus: 256 bits state + 512 bits message schedule = 768 bits
    type stage_bus_t is record
        state : ncl_logic_vector(255 downto 0);
        ws    : ncl_logic_vector(511 downto 0);
    end record;

    type stage_array_t is array (0 to 64) of stage_bus_t;
    signal stage : stage_array_t;

    -- Helper to extract/pack 32-bit words from state vector
    -- State packing: a=bits[255:224], b=[223:192], ..., h=[31:0]
    function get_state_word(s : ncl_logic_vector; i : natural)
        return ncl_logic_vector is
        variable r : ncl_logic_vector(31 downto 0);
    begin
        for b in 0 to 31 loop
            r(b) := s((7-i)*32 + b);
        end loop;
        return r;
    end function;

    function pack_state(a,b,c,d,e,f,g,h : ncl_logic_vector)
        return ncl_logic_vector is
        variable s : ncl_logic_vector(255 downto 0);
    begin
        s(255 downto 224) := a; s(223 downto 192) := b;
        s(191 downto 160) := c; s(159 downto 128) := d;
        s(127 downto  96) := e; s( 95 downto  64) := f;
        s( 63 downto  32) := g; s( 31 downto   0) := h;
        return s;
    end function;

begin
    -- Pipeline input
    stage(0).state <= state_in;
    stage(0).ws    <= msg_in;

    -- Generate 64 stages
    gen_stages: for i in 0 to 63 generate
        signal a_i, b_i, c_i, d_i, e_i, f_i, g_i, h_i : ncl_logic_vector(31 downto 0);
        signal a_o, b_o, c_o, d_o, e_o, f_o, g_o, h_o : ncl_logic_vector(31 downto 0);
        signal w_current : ncl_logic_vector(31 downto 0);
        signal ws_next   : ncl_logic_vector(511 downto 0);
        signal k_ncl     : ncl_logic_vector(31 downto 0);
    begin
        -- Unpack state
        a_i <= get_state_word(stage(i).state, 0);
        b_i <= get_state_word(stage(i).state, 1);
        c_i <= get_state_word(stage(i).state, 2);
        d_i <= get_state_word(stage(i).state, 3);
        e_i <= get_state_word(stage(i).state, 4);
        f_i <= get_state_word(stage(i).state, 5);
        g_i <= get_state_word(stage(i).state, 6);
        h_i <= get_state_word(stage(i).state, 7);

        -- Encode round constant
        k_ncl <= ncl_encode(K(i));

        -- Message schedule expansion
        u_w_exp: entity work.e_sha256_w_expand(ncl_comb)
            port map (
                ws_in  => stage(i).ws,
                w_out  => w_current,
                ws_out => ws_next
            );

        -- Round function
        u_round: entity work.e_sha256_round(ncl_comb)
            port map (
                a_in => a_i, b_in => b_i, c_in => c_i, d_in => d_i,
                e_in => e_i, f_in => f_i, g_in => g_i, h_in => h_i,
                k_i  => k_ncl, w_i => w_current,
                a_out => a_o, b_out => b_o, c_out => c_o, d_out => d_o,
                e_out => e_o, f_out => f_o, g_out => g_o, h_out => h_o
            );

        -- Pipeline register (FPGA: rising_edge(phase); ASIC: NCL latch)
        stage_reg: process(phase, clr)
        begin
            if clr = '1' then
                stage(i+1).state <= (others => NCL_DATA0);
                stage(i+1).ws    <= (others => NCL_DATA0);
            elsif rising_edge(phase) then
                stage(i+1).state <= pack_state(a_o, b_o, c_o, d_o,
                                              e_o, f_o, g_o, h_o);
                stage(i+1).ws    <= ws_next;
            end if;
        end process;
    end generate;

    -- Pipeline output: final state from stage 63
    state_out <= stage(64).state;
end architecture;
