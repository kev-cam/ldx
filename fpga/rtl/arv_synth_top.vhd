-- arv_synth_top.vhd — minimal FPGA synthesis wrapper for ARV CPU.
--
-- Purpose: prove that e_arv_cpu (and the ncl_sync package) elaborate
-- and synthesize to the DE2i-150 fabric. Not a real SoC — just a tiny
-- ROM for fetch, a tiny RAM for data, and an LED driven by a debug
-- output so the synthesizer can't optimize the whole CPU away.
--
-- Phase generation: divide clk by 2, so one full ARV cycle (rising +
-- falling edge of `phase`) takes 2 clk periods.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity arv_synth_top is
    port (
        clk    : in  std_logic;
        resetn : in  std_logic;
        led    : out std_logic_vector(3 downto 0)
    );
end entity arv_synth_top;

architecture rtl of arv_synth_top is
    constant XLEN : positive := 32;

    signal phase     : std_logic := '0';
    signal clr       : std_logic;

    -- CPU buses
    signal mem_addr   : ncl_logic_vector(XLEN-1 downto 0);
    signal mem_wdata  : ncl_logic_vector(XLEN-1 downto 0);
    signal mem_rdata  : ncl_logic_vector(XLEN-1 downto 0);
    signal mem_read   : ncl_logic;
    signal mem_write  : ncl_logic;
    signal mem_valid  : ncl_logic;
    signal mem_ready  : ncl_logic;
    signal dmem_addr  : ncl_logic_vector(XLEN-1 downto 0);
    signal dmem_wdata : ncl_logic_vector(XLEN-1 downto 0);
    signal dmem_rdata : ncl_logic_vector(XLEN-1 downto 0);
    signal dmem_read  : ncl_logic;
    signal dmem_write : ncl_logic;
    signal cfu_cmd    : ncl_logic_vector(XLEN-1 downto 0);
    signal cfu_arg    : ncl_logic_vector(XLEN-1 downto 0);
    signal cfu_funct3 : ncl_logic_vector(2 downto 0);
    signal cfu_result : ncl_logic_vector(XLEN-1 downto 0);
    signal cfu_valid  : ncl_logic;
    signal cfu_ready  : ncl_logic;
    signal dbg_alu, dbg_rd : ncl_logic_vector(XLEN-1 downto 0);
    signal dbg_rd_wen      : ncl_logic;
    signal dbg_rd_addr     : ncl_logic_vector(4 downto 0);

    -- Tiny instruction ROM (16 words)
    type rom_t is array (0 to 15) of std_logic_vector(31 downto 0);
    constant rom : rom_t := (
        0  => X"02A00093",  -- ADDI x1, x0, 42
        1  => X"03A00113",  -- ADDI x2, x0, 58
        2  => X"002081B3",  -- ADD  x3, x1, x2
        3  => X"40110233",  -- SUB  x4, x2, x1
        4  => X"0020F2B3",  -- AND  x5, x1, x2
        5  => X"0020E333",  -- OR   x6, x1, x2
        6  => X"0020C3B3",  -- XOR  x7, x1, x2
        7  => X"FE5FF06F",  -- JAL  x0, -28 (loop back to 0)
        others => X"00000013"  -- NOP
    );

    -- Tiny data RAM (16 words)
    type ram_t is array (0 to 15) of std_logic_vector(31 downto 0);
    signal ram : ram_t := (others => (others => '0'));

    signal led_reg : std_logic_vector(3 downto 0) := (others => '0');
begin
    -- Active-low reset → active-high clr for the CPU
    clr <= not resetn;

    -- Phase = clk / 2
    phase_proc: process(clk, resetn)
    begin
        if resetn = '0' then
            phase <= '0';
        elsif rising_edge(clk) then
            phase <= not phase;
        end if;
    end process;

    -- Instruction fetch: combinational ROM lookup
    fetch_rom: process(mem_addr)
        variable idx : integer range 0 to 15;
    begin
        idx := to_integer(unsigned(ncl_decode(mem_addr)(5 downto 2)));
        mem_rdata <= ncl_encode(rom(idx));
    end process;
    mem_ready <= NCL_DATA1;

    -- Data memory: combinational read, phase-driven write
    dmem_read_proc: process(dmem_addr, ram)
        variable idx : integer range 0 to 15;
    begin
        idx := to_integer(unsigned(ncl_decode(dmem_addr)(5 downto 2)));
        dmem_rdata <= ncl_encode(ram(idx));
    end process;

    dmem_write_proc: process(phase)
        variable idx : integer range 0 to 15;
    begin
        if falling_edge(phase) then
            if ncl_decode(dmem_write) = '1' then
                idx := to_integer(unsigned(ncl_decode(dmem_addr)(5 downto 2)));
                ram(idx) <= ncl_decode(dmem_wdata);
            end if;
        end if;
    end process;

    -- Stub CFU: echo rs1
    cfu_result <= cfu_cmd;
    cfu_ready  <= cfu_valid;

    -- LED: bottom 4 bits of dbg_alu, latched on falling phase
    led_proc: process(phase)
    begin
        if falling_edge(phase) then
            led_reg <= ncl_decode(dbg_alu)(3 downto 0);
        end if;
    end process;
    led <= led_reg;

    cpu: entity work.e_arv_cpu(ncl_cpu)
        generic map (XLEN => XLEN, RESET_ADDR => X"00000000")
        port map (
            mem_addr => mem_addr, mem_wdata => mem_wdata,
            mem_rdata => mem_rdata, mem_read => mem_read,
            mem_write => mem_write, mem_valid => mem_valid,
            mem_ready => mem_ready,
            dmem_addr => dmem_addr, dmem_wdata => dmem_wdata,
            dmem_rdata => dmem_rdata,
            dmem_read => dmem_read, dmem_write => dmem_write,
            cfu_cmd => cfu_cmd, cfu_arg => cfu_arg,
            cfu_funct3 => cfu_funct3, cfu_result => cfu_result,
            cfu_valid => cfu_valid, cfu_ready => cfu_ready,
            dbg_alu_result => dbg_alu, dbg_rd_data => dbg_rd,
            dbg_rd_wen => dbg_rd_wen, dbg_rd_addr => dbg_rd_addr,
            phase => phase, clr => clr);
end architecture rtl;
