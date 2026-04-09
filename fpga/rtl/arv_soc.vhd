-- arv_soc.vhd — ARV-based SoC, drop-in replacement for ldx_soc.v.
--
-- Same Avalon-MM slave port shape as the VexRiscv-based ldx_soc, so
-- the QSYS pcie_system can instantiate this without changes (via a
-- thin Verilog shim that maps the Verilog module name to this VHDL
-- entity).
--
-- Internals:
--   * clk_50 → phase divider (clk/4) → ARV CPU clock domain
--   * Power-on reset chain: PCIe `reset` + cpu_reset_reg → rst_delay
--     → cpu_rst → clr to ARV
--   * Inferred dual-port 4 KB RAM (1024 × 32 bit):
--       Port A → ARV instruction fetch (read-only)
--       Port B → ARV data port + PCIe access (read/write)
--   * I/O space (CPU writes to 0xF000_0000..0xF000_0010):
--       0x00 → cpu_result[0]
--       0x04 → cpu_done  (1 = program finished)
--       0x08 → cpu_result[1]
--       0x0C → cpu_result[2]
--       0x10 → cpu_result[3]
--   * PCIe BAR0 layout (word-addressed, 11-bit address):
--       0x000-0x3FF : RAM (write only when cpu_reset_reg=1)
--       0x7C0      : control (bit 0 = cpu_reset_reg)
--       0x7C1      : status (bit 0 = cpu_done)
--       0x7C2-0x7C5: cpu_result[0..3]
--       0x7E0      : magic "LDX2" = 0x4C445832
--   * CFU is currently stubbed (cfu_result <= cfu_cmd, echoes rs1).
--     Wiring it to the real ldx_cfu requires adding pipeline stalls
--     to ARV (Phase 4 — not blocking the SoC swap milestone).

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
library ncl;
use ncl.ncl.all;

entity arv_soc is
    port (
        clk        : in  std_logic;
        reset      : in  std_logic;
        reset_req  : in  std_logic;
        address    : in  std_logic_vector(10 downto 0);
        read       : in  std_logic;
        write      : in  std_logic;
        readdata   : out std_logic_vector(31 downto 0);
        writedata  : in  std_logic_vector(31 downto 0);
        byteenable : in  std_logic_vector(3 downto 0);
        chipselect : in  std_logic
    );
end entity arv_soc;

architecture rtl of arv_soc is
    -- ---- Reset chain ----
    signal cpu_reset_reg : std_logic := '1';
    signal rst_delay     : unsigned(3 downto 0) := (others => '1');
    signal cpu_rst       : std_logic;
    signal clr           : std_logic;

    -- ---- Phase divider (clk / 4 → ARV instruction every 80 ns @ 50 MHz) ----
    signal phase_cnt : unsigned(1 downto 0) := (others => '0');
    signal phase     : std_logic := '0';

    -- ---- I/O and control registers ----
    signal cpu_done   : std_logic := '0';
    type result_array_t is array (0 to 3) of std_logic_vector(31 downto 0);
    signal cpu_result : result_array_t := (others => (others => '0'));

    -- ---- ARV CPU buses (NCL domain) ----
    signal arv_mem_addr   : ncl_logic_vector(31 downto 0);
    signal arv_mem_wdata  : ncl_logic_vector(31 downto 0);
    signal arv_mem_rdata  : ncl_logic_vector(31 downto 0);
    signal arv_mem_read   : ncl_logic;
    signal arv_mem_write  : ncl_logic;
    signal arv_mem_valid  : ncl_logic;
    signal arv_mem_ready  : ncl_logic;

    signal arv_dmem_addr  : ncl_logic_vector(31 downto 0);
    signal arv_dmem_wdata : ncl_logic_vector(31 downto 0);
    signal arv_dmem_rdata : ncl_logic_vector(31 downto 0);
    signal arv_dmem_read  : ncl_logic;
    signal arv_dmem_write : ncl_logic;

    signal arv_cfu_cmd    : ncl_logic_vector(31 downto 0);
    signal arv_cfu_arg    : ncl_logic_vector(31 downto 0);
    signal arv_cfu_funct3 : ncl_logic_vector(2 downto 0);
    signal arv_cfu_result : ncl_logic_vector(31 downto 0);
    signal arv_cfu_valid  : ncl_logic;
    signal arv_cfu_ready  : ncl_logic;

    -- ---- Binary versions for the RAM / MMIO interface ----
    signal mem_addr_bin   : std_logic_vector(31 downto 0);
    signal dmem_addr_bin  : std_logic_vector(31 downto 0);
    signal dmem_wdata_bin : std_logic_vector(31 downto 0);
    signal dmem_write_bin : std_logic;

    signal dmem_is_ram : std_logic;
    signal dmem_is_io  : std_logic;

    -- ---- Inferred dual-port RAM ----
    type ram_t is array (0 to 1023) of std_logic_vector(31 downto 0);
    signal ram_mem : ram_t := (others => (others => '0'));

    signal porta_addr  : std_logic_vector(9 downto 0);
    signal porta_q     : std_logic_vector(31 downto 0);
    signal portb_addr  : std_logic_vector(9 downto 0);
    signal portb_wdata : std_logic_vector(31 downto 0);
    signal portb_we    : std_logic;
    signal portb_q     : std_logic_vector(31 downto 0);

    -- ---- Avalon-MM read pipeline ----
    signal addr_r : std_logic_vector(10 downto 0) := (others => '0');
begin
    -- ---- Reset chain: hold cpu_rst high for 16 clk cycles after either
    --      board reset or a host write that clears cpu_reset_reg ----
    rst_delay_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' or cpu_reset_reg = '1' then
                rst_delay <= "1111";
            elsif rst_delay /= "0000" then
                rst_delay <= rst_delay - 1;
            end if;
        end if;
    end process;
    cpu_rst <= '1' when rst_delay /= "0000" else '0';
    clr     <= cpu_rst;

    -- ---- Phase divider: clk / 4 ----
    phase_proc: process(clk)
    begin
        if rising_edge(clk) then
            if cpu_rst = '1' then
                phase_cnt <= (others => '0');
                phase     <= '0';
            else
                phase_cnt <= phase_cnt + 1;
                phase     <= phase_cnt(1);
            end if;
        end if;
    end process;

    -- ---- ARV CPU ----
    cpu: entity work.e_arv_cpu(ncl_cpu)
        generic map (XLEN => 32, RESET_ADDR => X"80000000")
        port map (
            mem_addr   => arv_mem_addr,
            mem_wdata  => arv_mem_wdata,
            mem_rdata  => arv_mem_rdata,
            mem_read   => arv_mem_read,
            mem_write  => arv_mem_write,
            mem_valid  => arv_mem_valid,
            mem_ready  => arv_mem_ready,
            dmem_addr  => arv_dmem_addr,
            dmem_wdata => arv_dmem_wdata,
            dmem_rdata => arv_dmem_rdata,
            dmem_read  => arv_dmem_read,
            dmem_write => arv_dmem_write,
            cfu_cmd    => arv_cfu_cmd,
            cfu_arg    => arv_cfu_arg,
            cfu_funct3 => arv_cfu_funct3,
            cfu_result => arv_cfu_result,
            cfu_valid  => arv_cfu_valid,
            cfu_ready  => arv_cfu_ready,
            dbg_alu_result => open,
            dbg_rd_data    => open,
            dbg_rd_wen     => open,
            dbg_rd_addr    => open,
            phase => phase, clr => clr
        );
    arv_mem_ready <= NCL_DATA1;

    -- Stub CFU: echo rs1 (real CFU integration deferred until ARV
    -- has pipeline stalls for multi-cycle accelerators).
    arv_cfu_result <= arv_cfu_cmd;
    arv_cfu_ready  <= arv_cfu_valid;

    -- ---- NCL → binary at the bus boundary ----
    mem_addr_bin   <= ncl_decode(arv_mem_addr);
    dmem_addr_bin  <= ncl_decode(arv_dmem_addr);
    dmem_wdata_bin <= ncl_decode(arv_dmem_wdata);
    dmem_write_bin <= ncl_decode(arv_dmem_write);

    dmem_is_ram <= '1' when dmem_addr_bin(31 downto 28) = "1000" else '0';
    dmem_is_io  <= '1' when dmem_addr_bin(31 downto 28) = "1111" else '0';

    -- ---- Port A: instruction fetch (read-only) ----
    porta_addr <= mem_addr_bin(11 downto 2);

    -- ---- Port B: arbitrated between PCIe (in reset) and ARV dmem ----
    portb_arb: process(cpu_reset_reg, address, write, chipselect, writedata,
                       dmem_addr_bin, dmem_wdata_bin, dmem_write_bin, dmem_is_ram)
    begin
        if cpu_reset_reg = '1' then
            -- Host owns port B for RAM loading
            portb_addr  <= address(9 downto 0);
            portb_wdata <= writedata;
            portb_we    <= chipselect and write and (not address(10));
        else
            -- ARV owns port B for data accesses
            portb_addr  <= dmem_addr_bin(11 downto 2);
            portb_wdata <= dmem_wdata_bin;
            portb_we    <= dmem_write_bin and dmem_is_ram;
        end if;
    end process;

    -- Inferred dual-port RAM: one process, one signal, two clock-edge
    -- read assignments — Quartus recognises this as a synchronous M9K
    -- dual-port and infers block RAM.
    ram_proc: process(clk)
    begin
        if rising_edge(clk) then
            if portb_we = '1' then
                ram_mem(to_integer(unsigned(portb_addr))) <= portb_wdata;
            end if;
            porta_q <= ram_mem(to_integer(unsigned(porta_addr)));
            portb_q <= ram_mem(to_integer(unsigned(portb_addr)));
        end if;
    end process;

    arv_mem_rdata  <= ncl_encode(porta_q);
    arv_dmem_rdata <= ncl_encode(portb_q);

    -- ---- I/O writes from the CPU (0xF000_0000..0xF000_0010) ----
    io_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cpu_done   <= '0';
                cpu_result <= (others => (others => '0'));
            elsif cpu_reset_reg = '0' and dmem_write_bin = '1' and dmem_is_io = '1' then
                case dmem_addr_bin(7 downto 0) is
                    when X"00" => cpu_result(0) <= dmem_wdata_bin;
                    when X"04" => cpu_done      <= '1';
                    when X"08" => cpu_result(1) <= dmem_wdata_bin;
                    when X"0C" => cpu_result(2) <= dmem_wdata_bin;
                    when X"10" => cpu_result(3) <= dmem_wdata_bin;
                    when others => null;
                end case;
            elsif chipselect = '1' and write = '1'
                  and address = "11111000000"  -- 0x7C0
                  and writedata(0) = '0' then
                -- Host releases CPU reset → also clears done flag
                cpu_done <= '0';
            end if;
        end if;
    end process;

    -- ---- PCIe control register: cpu_reset_reg ----
    ctrl_proc: process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                cpu_reset_reg <= '1';
            elsif chipselect = '1' and write = '1'
                  and address = "11111000000" then  -- 0x7C0
                cpu_reset_reg <= writedata(0);
            end if;
        end if;
    end process;

    -- ---- Avalon-MM read (1-cycle latency: address registered) ----
    addr_r_proc: process(clk)
    begin
        if rising_edge(clk) then
            addr_r <= address;
        end if;
    end process;

    read_proc: process(addr_r, portb_q, cpu_reset_reg, cpu_done, cpu_result)
        variable rd : std_logic_vector(31 downto 0);
    begin
        rd := (others => '0');
        if addr_r(10) = '0' then
            rd := portb_q;  -- RAM read (first 0x400 words)
        else
            case addr_r is
                when "11111000000" => rd(0) := cpu_reset_reg;            -- 0x7C0
                when "11111000001" => rd(0) := cpu_done;                 -- 0x7C1
                when "11111000010" => rd := cpu_result(0);                -- 0x7C2
                when "11111000011" => rd := cpu_result(1);                -- 0x7C3
                when "11111000100" => rd := cpu_result(2);                -- 0x7C4
                when "11111000101" => rd := cpu_result(3);                -- 0x7C5
                when "11111100000" => rd := X"4C445832";                  -- 0x7E0 "LDX2"
                when others        => rd := (others => '0');
            end case;
        end if;
        readdata <= rd;
    end process;

end architecture rtl;
