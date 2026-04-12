#!/usr/bin/env python3
"""sim_bench.py — Run an ARV binary in NVC simulation, report cycle count + results.

Usage: python3 sim_bench.py sha256_sw.bin sha256_cfu.bin
"""
import struct, subprocess, sys, os, tempfile

EXPECTED = [0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223]

ARV_SRCS = [
    "/usr/local/src/arv/RISC-V.srcs/asynchronous/cpu/regfile.vhdl",
    "/usr/local/src/arv/RISC-V.srcs/asynchronous/cpu/decoder.vhdl",
    "/usr/local/src/arv/RISC-V.srcs/asynchronous/cpu/execute.vhdl",
    "/usr/local/src/arv/RISC-V.srcs/asynchronous/cpu/arv_cpu.vhdl",
]

TB_TEMPLATE = '''
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity tb_bench is end entity;

architecture test of tb_bench is
    constant XLEN : positive := 32;
    signal mem_addr, mem_wdata, mem_rdata : ncl_logic_vector(XLEN-1 downto 0);
    signal mem_read, mem_write, mem_valid, mem_ready : ncl_logic;
    signal dmem_addr, dmem_wdata, dmem_rdata : ncl_logic_vector(XLEN-1 downto 0);
    signal dmem_read, dmem_write : ncl_logic;
    signal cfu_cmd, cfu_arg, cfu_result : ncl_logic_vector(XLEN-1 downto 0);
    signal cfu_funct3 : ncl_logic_vector(2 downto 0);
    signal cfu_valid, cfu_ready : ncl_logic;
    signal dbg_alu, dbg_rd : ncl_logic_vector(XLEN-1 downto 0);
    signal dbg_rd_wen : ncl_logic;
    signal dbg_rd_addr : ncl_logic_vector(4 downto 0);
    signal phase : std_logic := '0';
    signal clr : std_logic := '1';

    type mem_t is array (0 to 1023) of std_logic_vector(31 downto 0);
    signal mem : mem_t := (
{MEM_INIT},
        others => X"00000013"
    );

    signal io_r0, io_r1, io_r2, io_r3 : std_logic_vector(31 downto 0) := (others => '0');
    signal io_done : std_logic := '0';
begin
    dut: entity work.e_arv_cpu(ncl_cpu)
        generic map (XLEN => XLEN, RESET_ADDR => X"80000000")
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

    mem_proc: process(mem_addr)
        variable idx : integer;
    begin
        if ncl_is_null(mem_addr) then
            mem_rdata <= (others => NCL_NULL);
        else
            idx := to_integer(unsigned(ncl_decode(mem_addr)(11 downto 2)));
            mem_rdata <= ncl_encode(mem(idx));
        end if;
    end process;

    dmem_read_proc: process(dmem_addr, mem)
        variable idx : integer;
        variable addr : std_logic_vector(31 downto 0);
    begin
        if ncl_is_null(dmem_addr) then
            dmem_rdata <= (others => NCL_NULL);
        else
            addr := ncl_decode(dmem_addr);
            if addr(31 downto 28) = "1000" then
                idx := to_integer(unsigned(addr(11 downto 2)));
                dmem_rdata <= ncl_encode(mem(idx));
            else
                dmem_rdata <= (others => NCL_DATA0);
            end if;
        end if;
    end process;

    dmem_write_proc: process(phase)
        variable addr : std_logic_vector(31 downto 0);
        variable dv : std_logic_vector(31 downto 0);
        variable idx : integer;
    begin
        if falling_edge(phase) then
            if ncl_is_data(dmem_write) and ncl_decode(dmem_write) = '1'
               and ncl_is_data(dmem_addr) and ncl_is_data(dmem_wdata) then
                addr := ncl_decode(dmem_addr);
                dv := ncl_decode(dmem_wdata);
                if addr(31 downto 28) = "1000" then
                    idx := to_integer(unsigned(addr(11 downto 2)));
                    mem(idx) <= dv;
                elsif addr(31 downto 28) = "1111" then
                    case addr(7 downto 0) is
                        when X"00" => io_r0 <= dv;
                        when X"04" => io_done <= '1';
                        when X"08" => io_r1 <= dv;
                        when X"0C" => io_r2 <= dv;
                        when X"10" => io_r3 <= dv;
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- CFU model: function 5 = rotr(rs1, rs2[4:0]), others = echo rs1
    cfu_proc: process(cfu_cmd, cfu_arg, cfu_funct3)
        variable rs1, rs2, r : std_logic_vector(31 downto 0);
        variable shamt : integer;
    begin
        if ncl_is_data(cfu_cmd) and ncl_is_data(cfu_funct3) then
            rs1 := ncl_decode(cfu_cmd);
            rs2 := ncl_decode(cfu_arg);
            if ncl_decode(cfu_funct3) = "101" then
                shamt := to_integer(unsigned(rs2(4 downto 0)));
                r := std_logic_vector(shift_right(unsigned(rs1), shamt)
                     or shift_left(unsigned(rs1), 32 - shamt));
                cfu_result <= ncl_encode(r);
            else
                cfu_result <= cfu_cmd;
            end if;
        else
            cfu_result <= (others => NCL_NULL);
        end if;
    end process;
    cfu_ready <= cfu_valid; mem_ready <= NCL_DATA1;

    stim: process
        procedure step is begin
            phase <= '1'; wait for 10 ns;
            phase <= '0'; wait for 10 ns;
        end procedure;
    begin
        wait for 1 ns;
        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;
        for i in 1 to 50000 loop
            step;
            if io_done = '1' then
                report "CYCLES:" & integer'image(i);
                exit;
            end if;
        end loop;
        if io_done = '0' then report "TIMEOUT" severity error; end if;
        report "R0:0x" & to_hstring(unsigned(io_r0));
        report "R1:0x" & to_hstring(unsigned(io_r1));
        report "R2:0x" & to_hstring(unsigned(io_r2));
        report "R3:0x" & to_hstring(unsigned(io_r3));
        wait;
    end process;
end architecture test;
'''

def bin_to_mem_init(binpath):
    data = open(binpath, "rb").read()
    lines = []
    for i in range(0, len(data), 4):
        w = struct.unpack_from("<I", data, i)[0] if i + 4 <= len(data) else 0
        lines.append(f'        {i // 4} => X"{w:08X}"')
    return ",\n".join(lines)

def run_sim(binpath):
    mem_init = bin_to_mem_init(binpath)
    vhdl = TB_TEMPLATE.replace("{MEM_INIT}", mem_init)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".vhdl", delete=False) as f:
        f.write(vhdl)
        tb_path = f.name

    try:
        cmd = ["nvc", "--std=08"] + ["-a"] + ARV_SRCS + [tb_path] + ["-e", "tb_bench", "-r"]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr

        cycles = None
        results = [None] * 4
        for line in output.split("\n"):
            if "CYCLES:" in line:
                cycles = int(line.split("CYCLES:")[1].strip())
            for ri in range(4):
                tag = f"R{ri}:0x"
                if tag in line:
                    hex_val = line.split(tag)[1].strip()[:8]
                    results[ri] = int(hex_val, 16)
            if "TIMEOUT" in line:
                cycles = -1

        return cycles, results
    finally:
        os.unlink(tb_path)

def main():
    if len(sys.argv) < 2:
        print(f"usage: {sys.argv[0]} <bin1> [bin2 ...]")
        sys.exit(1)

    print(f"{'Binary':<30} {'Cycles':>8}  {'Hash[0]':>10}  {'Status':>6}")
    print("-" * 60)

    all_results = {}
    for binpath in sys.argv[1:]:
        name = os.path.basename(binpath)
        cycles, results = run_sim(binpath)
        ok = results == EXPECTED
        status = "OK" if ok else ("TIMEOUT" if cycles == -1 else "WRONG")
        h0 = f"0x{results[0]:08X}" if results[0] is not None else "???"
        print(f"{name:<30} {cycles:>8}  {h0}  {status}")
        all_results[name] = cycles

    if len(all_results) >= 2:
        names = list(all_results.keys())
        c1, c2 = all_results[names[0]], all_results[names[1]]
        if c1 and c2 and c1 > 0 and c2 > 0:
            print(f"\nSpeedup: {c1/c2:.2f}x ({names[0]}: {c1} cycles, {names[1]}: {c2} cycles)")

if __name__ == "__main__":
    main()
