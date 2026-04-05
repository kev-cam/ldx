-- tb_arv_cpu.vhdl — Test ARV async RISC-V CPU executing RV32I instructions.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity tb_arv_cpu is end entity;

architecture test of tb_arv_cpu is
    constant XLEN : positive := 32;
    signal mem_addr, mem_wdata, mem_rdata : ncl_logic_vector(XLEN-1 downto 0);
    signal mem_read, mem_write, mem_valid, mem_ready : ncl_logic;
    signal cfu_cmd, cfu_arg, cfu_result : ncl_logic_vector(XLEN-1 downto 0);
    signal cfu_funct3 : ncl_logic_vector(2 downto 0);
    signal cfu_valid, cfu_ready : ncl_logic;
    signal dbg_alu, dbg_rd : ncl_logic_vector(XLEN-1 downto 0);
    signal dbg_rd_wen : ncl_logic;
    signal dbg_rd_addr : ncl_logic_vector(4 downto 0);
    signal phase : std_logic := '0';
    signal clr : std_logic := '1';

    type mem_t is array (0 to 255) of std_logic_vector(31 downto 0);
    signal mem : mem_t := (others => X"00000013");
    signal pass_count, fail_count : integer := 0;
begin
    dut: entity work.e_arv_cpu(ncl_cpu)
        generic map (XLEN => XLEN, RESET_ADDR => X"80000000")
        port map (
            mem_addr => mem_addr, mem_wdata => mem_wdata,
            mem_rdata => mem_rdata, mem_read => mem_read,
            mem_write => mem_write, mem_valid => mem_valid,
            mem_ready => mem_ready,
            cfu_cmd => cfu_cmd, cfu_arg => cfu_arg,
            cfu_funct3 => cfu_funct3, cfu_result => cfu_result,
            cfu_valid => cfu_valid, cfu_ready => cfu_ready,
            dbg_alu_result => dbg_alu, dbg_rd_data => dbg_rd,
            dbg_rd_wen => dbg_rd_wen, dbg_rd_addr => dbg_rd_addr,
            phase => phase, clr => clr
        );

    mem_proc: process(mem_addr)
        variable idx : integer;
    begin
        if ncl_is_null(mem_addr) then
            mem_rdata <= (others => NCL_NULL);
        else
            idx := to_integer(unsigned(ncl_decode(mem_addr)(9 downto 2)));
            mem_rdata <= ncl_encode(mem(idx));
        end if;
    end process;

    cfu_result <= cfu_cmd;
    cfu_ready <= cfu_valid;
    mem_ready <= NCL_DATA1;

    stim: process
        procedure step is
        begin
            phase <= '1'; wait for 10 ns;  -- rising: latch insn, decode+execute
            phase <= '0'; wait for 10 ns;  -- falling: commit next_pc, writeback
        end procedure;

        procedure check(msg : string; got, expected : integer) is
        begin
            if got = expected then
                pass_count <= pass_count + 1;
                report msg & ": PASS (" & integer'image(got) & ")";
            else
                fail_count <= fail_count + 1;
                report msg & ": FAIL (got " & integer'image(got)
                     & ", expected " & integer'image(expected) & ")" severity error;
            end if;
        end procedure;

        variable alu_val : integer;
    begin
        -- ADDI x1, x0, 42
        mem(0) <= X"02A00093";
        -- ADDI x2, x0, 58
        mem(1) <= X"03A00113";
        -- ADD x3, x1, x2
        mem(2) <= X"002081B3";
        -- ADDI x4, x0, 7
        mem(3) <= X"00700213";
        -- NOP
        mem(4) <= X"00000013";

        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;

        -- Step 1: ADDI x1, x0, 42
        step;
        if ncl_is_data(dbg_alu) then
            alu_val := to_integer(unsigned(ncl_decode(dbg_alu)));
            check("ADDI x1,x0,42 => ALU", alu_val, 42);
        else
            report "ADDI x1: ALU result is NULL" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- Step 2: ADDI x2, x0, 58
        step;
        if ncl_is_data(dbg_alu) then
            alu_val := to_integer(unsigned(ncl_decode(dbg_alu)));
            check("ADDI x2,x0,58 => ALU", alu_val, 58);
        else
            report "ADDI x2: ALU result is NULL" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- Step 3: ADD x3, x1, x2 (should be 42+58=100)
        step;
        if ncl_is_data(dbg_alu) then
            alu_val := to_integer(unsigned(ncl_decode(dbg_alu)));
            check("ADD x3,x1,x2 => ALU", alu_val, 100);
        else
            report "ADD x3: ALU result is NULL" severity error;
            fail_count <= fail_count + 1;
        end if;

        -- Step 4: ADDI x4, x0, 7
        step;
        if ncl_is_data(dbg_alu) then
            alu_val := to_integer(unsigned(ncl_decode(dbg_alu)));
            check("ADDI x4,x0,7 => ALU", alu_val, 7);
        else
            report "ADDI x4: ALU result is NULL" severity error;
            fail_count <= fail_count + 1;
        end if;

        report "ARV CPU: " & integer'image(pass_count) & " passed, "
             & integer'image(fail_count) & " failed";
        if fail_count = 0 then report "ALL PASS"; end if;
        wait;
    end process;
end architecture test;
