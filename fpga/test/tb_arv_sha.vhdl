-- tb_arv_sha.vhdl — Run sha_debug.bin on ARV CPU in NVC simulation.
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity tb_arv_sha is end entity;

architecture test of tb_arv_sha is
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
        0 => X"80001137",
        1 => X"0040006F",
        2 => X"800007B7",
        3 => X"EB010113",
        4 => X"15478793",
        5 => X"14812623",
        6 => X"14912423",
        7 => X"15212223",
        8 => X"15312023",
        9 => X"04078693",
        10 => X"00010713",
        11 => X"0007A803",
        12 => X"0047A503",
        13 => X"0087A583",
        14 => X"00C7A603",
        15 => X"01072023",
        16 => X"00A72223",
        17 => X"00B72423",
        18 => X"00C72623",
        19 => X"01078793",
        20 => X"01070713",
        21 => X"FCD79CE3",
        22 => X"04010393",
        23 => X"00010793",
        24 => X"00038713",
        25 => X"0007A683",
        26 => X"00478793",
        27 => X"00470713",
        28 => X"FED72E23",
        29 => X"FEF398E3",
        30 => X"06412F83",
        31 => X"06812F03",
        32 => X"06C12E83",
        33 => X"07012E03",
        34 => X"07412303",
        35 => X"07812603",
        36 => X"07C12883",
        37 => X"04012683",
        38 => X"0C438393",
        39 => X"04410593",
        40 => X"00068293",
        41 => X"0005A683",
        42 => X"01165793",
        43 => X"00F61493",
        44 => X"01365513",
        45 => X"00D61413",
        46 => X"0076D713",
        47 => X"01969993",
        48 => X"0126D813",
        49 => X"00E69913",
        50 => X"01286833",
        51 => X"00856533",
        52 => X"01376733",
        53 => X"0097E7B3",
        54 => X"01074733",
        55 => X"00A7C7B3",
        56 => X"0036D813",
        57 => X"00A65513",
        58 => X"01074733",
        59 => X"00A7C7B3",
        60 => X"00E787B3",
        61 => X"01F787B3",
        62 => X"00088713",
        63 => X"005788B3",
        64 => X"0315AE23",
        65 => X"00458593",
        66 => X"000F0F93",
        67 => X"000E8F13",
        68 => X"000E0E93",
        69 => X"00030E13",
        70 => X"00060313",
        71 => X"00070613",
        72 => X"F8B390E3",
        73 => X"04012683",
        74 => X"F00007B7",
        75 => X"00100713",
        76 => X"00D7A023",
        77 => X"07C12683",
        78 => X"00D7A423",
        79 => X"08012683",
        80 => X"00D7A623",
        81 => X"08412683",
        82 => X"00D7A823",
        83 => X"00E7A223",
        84 => X"0000006F",
        85 => X"61626380",
        86 => X"00000000",
        87 => X"00000000",
        88 => X"00000000",
        89 => X"00000000",
        90 => X"00000000",
        91 => X"00000000",
        92 => X"00000000",
        93 => X"00000000",
        94 => X"00000000",
        95 => X"00000000",
        96 => X"00000000",
        97 => X"00000000",
        98 => X"00000000",
        99 => X"00000000",
        100 => X"00000018",
        others => X"00000013"
    );

    signal io_result0, io_result1, io_result2, io_result3 : std_logic_vector(31 downto 0) := (others => '0');
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
        variable data_v : std_logic_vector(31 downto 0);
        variable idx : integer;
    begin
        if falling_edge(phase) then
            if ncl_is_data(dmem_write) and ncl_decode(dmem_write) = '1'
               and ncl_is_data(dmem_addr) and ncl_is_data(dmem_wdata) then
                addr := ncl_decode(dmem_addr);
                data_v := ncl_decode(dmem_wdata);
                if addr(31 downto 28) = "1000" then
                    idx := to_integer(unsigned(addr(11 downto 2)));
                    mem(idx) <= data_v;
                elsif addr(31 downto 28) = "1111" then
                    case addr(7 downto 0) is
                        when X"00" => io_result0 <= data_v;
                        when X"04" => io_done    <= '1';
                        when X"08" => io_result1 <= data_v;
                        when X"0C" => io_result2 <= data_v;
                        when X"10" => io_result3 <= data_v;
                        when others => null;
                    end case;
                end if;
            end if;
        end if;
    end process;

    cfu_result <= cfu_cmd; cfu_ready <= cfu_valid; mem_ready <= NCL_DATA1;

    stim: process
        procedure step is begin
            phase <= '1'; wait for 10 ns;
            phase <= '0'; wait for 10 ns;
        end procedure;
    begin
        wait for 1 ns;
        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;

        for i in 1 to 10000 loop
            step;
            if io_done = '1' then
                report "DONE after " & integer'image(i) & " steps";
                exit;
            end if;
        end loop;

        if io_done = '0' then report "TIMEOUT" severity error; end if;

        report "result[0] = 0x" & to_hstring(unsigned(io_result0)) & "  (expect 0x61626380)";
        report "result[1] = 0x" & to_hstring(unsigned(io_result1)) & "  (expect 0x00000018)";
        report "result[2] = 0x" & to_hstring(unsigned(io_result2)) & "  (expect 0x61626380)";
        report "result[3] = 0x" & to_hstring(unsigned(io_result3)) & "  (expect 0x000F0000)";
        wait;
    end process;
end architecture test;
