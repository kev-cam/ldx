-- tb_arv_cpu.vhdl — Comprehensive ARV CPU test: arithmetic, branches, jumps.
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

    type mem_t is array (0 to 255) of std_logic_vector(31 downto 0);
    signal mem  : mem_t := (others => X"00000013");
    signal dmem : mem_t := (others => X"00000000");

    signal pass_count, fail_count : integer := 0;
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
            idx := to_integer(unsigned(ncl_decode(mem_addr)(9 downto 2)));
            mem_rdata <= ncl_encode(mem(idx));
        end if;
    end process;

    cfu_result <= cfu_cmd; cfu_ready <= cfu_valid; mem_ready <= NCL_DATA1;

    -- Data memory: combinational read, write on falling_edge of phase
    dmem_read_proc: process(dmem_addr, dmem)
        variable idx : integer;
    begin
        if ncl_is_null(dmem_addr) then
            dmem_rdata <= (others => NCL_NULL);
        else
            idx := to_integer(unsigned(ncl_decode(dmem_addr)(9 downto 2)));
            dmem_rdata <= ncl_encode(dmem(idx));
        end if;
    end process;

    dmem_write_proc: process(phase)
        variable idx : integer;
    begin
        if falling_edge(phase) then
            if ncl_is_data(dmem_write) and ncl_decode(dmem_write) = '1'
                  and ncl_is_data(dmem_addr) and ncl_is_data(dmem_wdata) then
                idx := to_integer(unsigned(ncl_decode(dmem_addr)(9 downto 2)));
                dmem(idx) <= ncl_decode(dmem_wdata);
            end if;
        end if;
    end process;

    stim: process
        procedure step is
        begin
            phase <= '1'; wait for 10 ns;
            phase <= '0'; wait for 10 ns;
        end procedure;

        procedure check_alu(msg : string; expected : integer) is
            variable got : integer;
        begin
            if ncl_is_data(dbg_alu) then
                got := to_integer(unsigned(ncl_decode(dbg_alu)));
                if got = expected then
                    pass_count <= pass_count + 1;
                    report msg & ": PASS (" & integer'image(got) & ")";
                else
                    fail_count <= fail_count + 1;
                    report msg & ": FAIL (got " & integer'image(got)
                         & ", expected " & integer'image(expected) & ")" severity error;
                end if;
            else
                fail_count <= fail_count + 1;
                report msg & ": FAIL (NULL)" severity error;
            end if;
        end procedure;

        procedure check_alu_hex(msg : string; expected : std_logic_vector) is
        begin
            if ncl_is_data(dbg_alu) then
                if ncl_decode(dbg_alu) = expected then
                    pass_count <= pass_count + 1;
                    report msg & ": PASS";
                else
                    fail_count <= fail_count + 1;
                    report msg & ": FAIL (got 0x" & to_hstring(unsigned(ncl_decode(dbg_alu)))
                         & ")" severity error;
                end if;
            else
                fail_count <= fail_count + 1;
                report msg & ": FAIL (NULL)" severity error;
            end if;
        end procedure;
    begin
        -- ============================================================
        -- Test 1: Arithmetic (reuse from before)
        -- ============================================================
        -- 0x00: ADDI x1, x0, 42
        mem(0) <= X"02A00093";
        -- 0x04: ADDI x2, x0, 58
        mem(1) <= X"03A00113";
        -- 0x08: ADD x3, x1, x2
        mem(2) <= X"002081B3";
        -- 0x0C: SUB x4, x2, x1
        mem(3) <= X"40110233";
        -- 0x10: AND x5, x1, x2
        mem(4) <= X"0020F2B3";
        -- 0x14: OR x6, x1, x2
        mem(5) <= X"0020E333";
        -- 0x18: XOR x7, x1, x2
        mem(6) <= X"0020C3B3";
        -- 0x1C: LUI x8, 0xDEADB
        mem(7) <= X"DEADB437";

        -- ============================================================
        -- Test 2: BNE loop (x9=10, x10=0, loop: x10+=42, x9-=1)
        -- ============================================================
        -- 0x20: ADDI x9, x0, 5 (smaller loop for faster test)
        mem(8) <= X"00500493";
        -- 0x24: ADDI x10, x0, 0
        mem(9) <= X"00000513";
        -- 0x28: ADD x10, x10, x1 (x10 += 42)
        mem(10) <= X"00150533";
        -- 0x2C: ADDI x9, x9, -1
        mem(11) <= X"FFF48493";
        -- 0x30: BNE x9, x0, -8
        mem(12) <= X"FE049CE3";

        -- ============================================================
        -- Test 3: After loop, verify x10 = 42*5 = 210
        -- Use ADDI x11, x10, 0 to read x10 through ALU
        -- ============================================================
        -- 0x34: ADDI x11, x10, 0
        mem(13) <= X"00050593";

        -- ============================================================
        -- Test 4: BEQ (always taken: skip one instruction)
        -- ============================================================
        -- 0x38: BEQ x0, x0, 8 (skip next insn)
        mem(14) <= X"00000463";
        -- 0x3C: ADDI x12, x0, 999 (should be SKIPPED)
        mem(15) <= X"3E700613";
        -- 0x40: ADDI x12, x0, 77 (should execute)
        mem(16) <= X"04D00613";

        -- 0x44: NOP
        mem(17) <= X"00000013";

        -- ============================================================
        -- Test 5: JAL x1, +12 (link x1=0x4C, jump to 0x54)
        -- ============================================================
        -- 0x48: JAL x1, +12
        mem(18) <= X"00C000EF";
        -- 0x4C: ADDI x13, x0, 999 (SKIPPED)
        mem(19) <= X"3E700693";
        -- 0x50: ADDI x15, x0, 111 (SKIPPED)
        mem(20) <= X"06F00793";
        -- 0x54: ADDI x14, x1, 0  (verify link: x14 = x1 = 0x4C)
        mem(21) <= X"00008713";

        -- ============================================================
        -- Test 6: JALR x17, x16, 0 (jump to addr in x16, link x17=0x60)
        -- ============================================================
        -- 0x58: ADDI x16, x0, 0x68
        mem(22) <= X"06800813";
        -- 0x5C: JALR x17, x16, 0
        mem(23) <= X"000808E7";
        -- 0x60: ADDI x18, x0, 222 (SKIPPED)
        mem(24) <= X"0DE00913";
        -- 0x64: ADDI x19, x0, 333 (SKIPPED)
        mem(25) <= X"14D00993";
        -- 0x68: ADDI x20, x17, 0  (verify link: x20 = x17 = 0x60)
        mem(26) <= X"00088A13";

        -- ============================================================
        -- Test 7: SW + LW (store/load roundtrip)
        -- ============================================================
        -- 0x6C: ADDI x21, x0, 0x100  (data address)
        mem(27) <= X"10000A93";
        -- 0x70: ADDI x22, x0, 0x55   (value to store)
        mem(28) <= X"05500B13";
        -- 0x74: SW x22, 0(x21)
        mem(29) <= X"016AA023";
        -- 0x78: LW x23, 0(x21)
        mem(30) <= X"000AAB83";
        -- 0x7C: ADDI x24, x23, 0     (verify: x24 = loaded value = 0x55)
        mem(31) <= X"000B8C13";

        -- ============================================================
        -- Test 8: CUSTOM_0 CFU dispatch (testbench echoes rs1 → result)
        -- ============================================================
        -- 0x80: CUSTOM_0 x25, x2, x0  (rd=25, rs1=2, rs2=0, funct3=0, opcode=0001011)
        mem(32) <= X"00010C8B";
        -- 0x84: ADDI x26, x25, 0  (verify: x26 = x25 = cfu(x1) = 42)
        mem(33) <= X"000C8D13";

        wait for 1 ns;
        clr <= '1'; wait for 5 ns;
        clr <= '0'; wait for 5 ns;

        -- === Arithmetic tests ===
        step; check_alu("ADDI x1,x0,42", 42);
        step; check_alu("ADDI x2,x0,58", 58);
        step; check_alu("ADD x3,x1,x2", 100);
        step; check_alu("SUB x4,x2,x1", 16);
        step; check_alu("AND x5,x1,x2", 42);
        step; check_alu("OR x6,x1,x2", 58);
        step; check_alu("XOR x7,x1,x2", 16);
        step; check_alu_hex("LUI x8,0xDEADB", X"DEADB000");

        -- === BNE loop: 5 iterations of x10 += 42 ===
        step; check_alu("ADDI x9,x0,5", 5);
        step; check_alu("ADDI x10,x0,0", 0);

        for i in 1 to 5 loop
            step;  -- ADD x10, x10, x1
            step;  -- ADDI x9, x9, -1
            step;  -- BNE (taken for i=1..4, falls through for i=5)
        end loop;

        -- === Verify loop result: x10 = 42*5 = 210 ===
        step; check_alu("x10 after loop (42*5)", 210);

        -- === BEQ skip test ===
        step;  -- BEQ x0, x0, 8 (taken — skips next)
        step;  -- Should be ADDI x12, x0, 77 (the skip target)
        check_alu("BEQ skip => x12=77", 77);

        step;  -- NOP

        -- === JAL test ===
        step;  -- JAL x1, +12 (jumps to 0x54, links x1=0x4C)
        step;  -- ADDI x14, x1, 0  (alu = x1 = 0x4C)
        check_alu_hex("JAL link x1=0x8000004C", X"8000004C");

        -- === JALR test ===
        step;  -- ADDI x16, x0, 0x68
        check_alu_hex("ADDI x16,x0,0x68", X"00000068");
        step;  -- JALR x17, x16, 0 (jumps to 0x68, links x17=0x60)
        step;  -- ADDI x20, x17, 0  (alu = x17 = 0x60)
        check_alu_hex("JALR link x17=0x80000060", X"80000060");

        -- === LW/SW test ===
        step;  -- ADDI x21, x0, 0x100
        check_alu("ADDI x21,x0,0x100", 256);
        step;  -- ADDI x22, x0, 0x55
        check_alu("ADDI x22,x0,0x55", 85);
        step;  -- SW x22, 0(x21)  -- writes dmem[0x40]=0x55 on falling edge
        step;  -- LW x23, 0(x21)  -- loads x23 = 0x55
        step;  -- ADDI x24, x23, 0  -- alu = x23 = 0x55
        check_alu("LW->ADDI x24=0x55", 85);

        -- === CUSTOM_0 CFU test ===
        step;  -- CUSTOM_0 x25, x2, x0  (cfu echoes rs1=58 → x25)
        step;  -- ADDI x26, x25, 0
        check_alu("CFU echo x2=58 -> x26", 58);

        report "";
        report "ARV CPU: " & integer'image(pass_count) & " passed, "
             & integer'image(fail_count) & " failed";
        if fail_count = 0 then report "ALL PASS"; end if;
        wait;
    end process;
end architecture test;
