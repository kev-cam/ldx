#!/usr/bin/env python3
"""
verilator_vs_nvc_benchmark.py — Direct comparison of Verilator vs NVC acceleration

Benchmarks simple circuits on both simulators to get real performance data.
Tests identical Verilog designs on both platforms for fair comparison.
"""

import subprocess
import time
import os
import tempfile
import statistics
from pathlib import Path

class VerilatorNvcBenchmark:
    """Benchmark Verilator against NVC acceleration."""

    def __init__(self):
        self.results = {}
        self.test_circuits = {}

    def create_test_circuits(self):
        """Create simple test circuits for benchmarking."""

        # Simple counter circuit
        self.test_circuits['counter'] = {
            'verilog': '''
module counter (
    input wire clk,
    input wire rst,
    input wire enable,
    output reg [31:0] count
);

always @(posedge clk or posedge rst) begin
    if (rst)
        count <= 32'h0;
    else if (enable)
        count <= count + 1;
end

endmodule''',
            'vhdl': '''
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity counter is
    port (
        clk : in STD_LOGIC;
        rst : in STD_LOGIC;
        enable : in STD_LOGIC;
        count : out STD_LOGIC_VECTOR(31 downto 0)
    );
end counter;

architecture behavioral of counter is
    signal count_reg : unsigned(31 downto 0);
begin
    process(clk, rst)
    begin
        if rst = '1' then
            count_reg <= (others => '0');
        elsif rising_edge(clk) then
            if enable = '1' then
                count_reg <= count_reg + 1;
            end if;
        end if;
    end process;
    count <= std_logic_vector(count_reg);
end behavioral;''',
            'testbench_cycles': 100000
        }

        # Shift register circuit
        self.test_circuits['shift_reg'] = {
            'verilog': '''
module shift_reg (
    input wire clk,
    input wire rst,
    input wire data_in,
    output wire [15:0] data_out
);

reg [15:0] shift_register;

always @(posedge clk or posedge rst) begin
    if (rst)
        shift_register <= 16'h0;
    else
        shift_register <= {shift_register[14:0], data_in};
end

assign data_out = shift_register;

endmodule''',
            'vhdl': '''
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity shift_reg is
    port (
        clk : in STD_LOGIC;
        rst : in STD_LOGIC;
        data_in : in STD_LOGIC;
        data_out : out STD_LOGIC_VECTOR(15 downto 0)
    );
end shift_reg;

architecture behavioral of shift_reg is
    signal shift_register : STD_LOGIC_VECTOR(15 downto 0);
begin
    process(clk, rst)
    begin
        if rst = '1' then
            shift_register <= (others => '0');
        elsif rising_edge(clk) then
            shift_register <= shift_register(14 downto 0) & data_in;
        end if;
    end process;
    data_out <= shift_register;
end behavioral;''',
            'testbench_cycles': 50000
        }

        # Simple ALU circuit
        self.test_circuits['alu'] = {
            'verilog': '''
module alu (
    input wire clk,
    input wire [31:0] a,
    input wire [31:0] b,
    input wire [2:0] op,
    output reg [31:0] result
);

always @(posedge clk) begin
    case (op)
        3'b000: result <= a + b;
        3'b001: result <= a - b;
        3'b010: result <= a & b;
        3'b011: result <= a | b;
        3'b100: result <= a ^ b;
        3'b101: result <= a << 1;
        3'b110: result <= a >> 1;
        default: result <= 32'h0;
    endcase
end

endmodule''',
            'vhdl': '''
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity alu is
    port (
        clk : in STD_LOGIC;
        a : in STD_LOGIC_VECTOR(31 downto 0);
        b : in STD_LOGIC_VECTOR(31 downto 0);
        op : in STD_LOGIC_VECTOR(2 downto 0);
        result : out STD_LOGIC_VECTOR(31 downto 0)
    );
end alu;

architecture behavioral of alu is
begin
    process(clk)
    begin
        if rising_edge(clk) then
            case op is
                when "000" => result <= std_logic_vector(unsigned(a) + unsigned(b));
                when "001" => result <= std_logic_vector(unsigned(a) - unsigned(b));
                when "010" => result <= a and b;
                when "011" => result <= a or b;
                when "100" => result <= a xor b;
                when "101" => result <= a(30 downto 0) & '0';
                when "110" => result <= '0' & a(31 downto 1);
                when others => result <= (others => '0');
            end case;
        end if;
    end process;
end behavioral;''',
            'testbench_cycles': 75000
        }

    def create_verilator_testbench(self, circuit_name: str, module_name: str, cycles: int) -> str:
        """Create C++ testbench for Verilator."""

        testbench_cpp = f'''
#include <iostream>
#include <verilated.h>
#include "V{module_name}.h"
#include <chrono>

int main(int argc, char** argv) {{
    Verilated::commandArgs(argc, argv);
    V{module_name}* dut = new V{module_name};

    auto start = std::chrono::high_resolution_clock::now();

    // Reset sequence
    dut->rst = 1;
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    dut->rst = 0;

    // Main simulation loop
    for (int cycle = 0; cycle < {cycles}; cycle++) {{
        // Set inputs based on circuit
'''

        if circuit_name == 'counter':
            testbench_cpp += '''
        dut->enable = (cycle % 10) != 0;  // Enable 90% of the time
'''
        elif circuit_name == 'shift_reg':
            testbench_cpp += '''
        dut->data_in = cycle & 1;  // Alternate input data
'''
        elif circuit_name == 'alu':
            testbench_cpp += '''
        dut->a = cycle * 123;
        dut->b = cycle * 456;
        dut->op = cycle % 8;
'''

        testbench_cpp += f'''
        // Clock cycle
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();
    }}

    auto end = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);

    std::cout << "Verilator {circuit_name}: " << {cycles} << " cycles in "
              << duration.count() << " microseconds" << std::endl;
    std::cout << "Rate: " << (double({cycles}) / duration.count()) << " MHz" << std::endl;

    delete dut;
    return 0;
}}'''

        return testbench_cpp

    def create_nvc_testbench(self, circuit_name: str, module_name: str, cycles: int) -> str:
        """Create VHDL testbench for NVC."""

        testbench_vhdl = f'''
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_{module_name} is
end tb_{module_name};

architecture test of tb_{module_name} is
    signal clk : STD_LOGIC := '0';
    signal rst : STD_LOGIC := '1';
'''

        if circuit_name == 'counter':
            testbench_vhdl += '''
    signal enable : STD_LOGIC := '0';
    signal count : STD_LOGIC_VECTOR(31 downto 0);
'''
        elif circuit_name == 'shift_reg':
            testbench_vhdl += '''
    signal data_in : STD_LOGIC := '0';
    signal data_out : STD_LOGIC_VECTOR(15 downto 0);
'''
        elif circuit_name == 'alu':
            testbench_vhdl += '''
    signal a : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal b : STD_LOGIC_VECTOR(31 downto 0) := (others => '0');
    signal op : STD_LOGIC_VECTOR(2 downto 0) := (others => '0');
    signal result : STD_LOGIC_VECTOR(31 downto 0);
'''

        testbench_vhdl += f'''
    constant CLK_PERIOD : time := 10 ns;

begin
    -- Instantiate DUT
    dut: entity work.{module_name}
        port map (
            clk => clk,
            rst => rst,
'''

        if circuit_name == 'counter':
            testbench_vhdl += '''
            enable => enable,
            count => count
'''
        elif circuit_name == 'shift_reg':
            testbench_vhdl += '''
            data_in => data_in,
            data_out => data_out
'''
        elif circuit_name == 'alu':
            testbench_vhdl += '''
            a => a,
            b => b,
            op => op,
            result => result
'''

        testbench_vhdl += f'''
        );

    -- Clock generation
    clk_process: process
    begin
        clk <= '0';
        wait for CLK_PERIOD/2;
        clk <= '1';
        wait for CLK_PERIOD/2;
    end process;

    -- Test process
    stim_proc: process
    begin
        -- Reset
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for CLK_PERIOD;

        -- Main test loop
        for cycle in 0 to {cycles-1} loop
'''

        if circuit_name == 'counter':
            testbench_vhdl += '''
            enable <= '1' when (cycle mod 10) /= 0 else '0';
'''
        elif circuit_name == 'shift_reg':
            testbench_vhdl += '''
            data_in <= '1' when (cycle mod 2) = 1 else '0';
'''
        elif circuit_name == 'alu':
            testbench_vhdl += '''
            a <= std_logic_vector(to_unsigned((cycle * 123) mod 65536, 32));
            b <= std_logic_vector(to_unsigned((cycle * 456) mod 65536, 32));
            op <= std_logic_vector(to_unsigned(cycle mod 8, 3));
'''

        testbench_vhdl += f'''
            wait for CLK_PERIOD;
        end loop;

        report "NVC {circuit_name} simulation completed: {cycles} cycles";
        wait;
    end process;

end test;'''

        return testbench_vhdl

    def run_verilator_benchmark(self, circuit_name: str, module_name: str) -> float:
        """Run Verilator benchmark and return execution time."""

        circuit = self.test_circuits[circuit_name]
        cycles = circuit['testbench_cycles']

        print(f"Running Verilator benchmark: {circuit_name}")

        with tempfile.TemporaryDirectory() as temp_dir:
            # Write Verilog source
            verilog_file = f"{temp_dir}/{module_name}.v"
            with open(verilog_file, 'w') as f:
                f.write(circuit['verilog'])

            # Write C++ testbench
            testbench_file = f"{temp_dir}/tb_{module_name}.cpp"
            testbench_code = self.create_verilator_testbench(circuit_name, module_name, cycles)
            with open(testbench_file, 'w') as f:
                f.write(testbench_code)

            try:
                # Run Verilator
                cmd = [
                    "verilator", "--cc", "--exe", "--build", "-j", "4",
                    "--top-module", module_name,
                    verilog_file, testbench_file
                ]

                result = subprocess.run(cmd, cwd=temp_dir, capture_output=True, text=True, timeout=60)

                if result.returncode != 0:
                    print(f"✗ Verilator compilation failed: {result.stderr}")
                    return None

                # Run the executable
                executable = f"{temp_dir}/obj_dir/V{module_name}"
                start_time = time.time()

                result = subprocess.run([executable], capture_output=True, text=True, timeout=30)

                exec_time = time.time() - start_time

                if result.returncode == 0:
                    print(f"✓ Verilator {circuit_name}: {exec_time:.3f}s")
                    # Extract rate from output
                    for line in result.stdout.split('\\n'):
                        if "Rate:" in line:
                            rate = float(line.split(':')[1].strip().split()[0])
                            print(f"  Rate: {rate:.1f} MHz")
                    return exec_time
                else:
                    print(f"✗ Verilator execution failed: {result.stderr}")
                    return None

            except Exception as e:
                print(f"✗ Verilator benchmark error: {e}")
                return None

    def run_nvc_benchmark(self, circuit_name: str, module_name: str) -> float:
        """Run NVC benchmark and return execution time."""

        circuit = self.test_circuits[circuit_name]
        cycles = circuit['testbench_cycles']

        print(f"Running NVC benchmark: {circuit_name}")

        with tempfile.TemporaryDirectory() as temp_dir:
            # Write VHDL source
            entity_file = f"{temp_dir}/{module_name}.vhdl"
            with open(entity_file, 'w') as f:
                f.write(circuit['vhdl'])

            # Write VHDL testbench
            testbench_file = f"{temp_dir}/tb_{module_name}.vhdl"
            testbench_code = self.create_nvc_testbench(circuit_name, module_name, cycles)
            with open(testbench_file, 'w') as f:
                f.write(testbench_code)

            try:
                # Run NVC
                start_time = time.time()

                steps = [
                    ["nvc", "-a", entity_file],
                    ["nvc", "-a", testbench_file],
                    ["nvc", "-e", f"tb_{module_name}"],
                    ["nvc", "-r", f"tb_{module_name}"]
                ]

                for step in steps:
                    result = subprocess.run(step, cwd=temp_dir, capture_output=True, text=True, timeout=30)
                    if result.returncode != 0:
                        print(f"✗ NVC step failed: {' '.join(step)}")
                        print(f"  Error: {result.stderr}")
                        return None

                exec_time = time.time() - start_time

                print(f"✓ NVC {circuit_name}: {exec_time:.3f}s")
                rate = cycles / (exec_time * 1000000)  # MHz
                print(f"  Rate: {rate:.1f} MHz")
                return exec_time

            except Exception as e:
                print(f"✗ NVC benchmark error: {e}")
                return None

    def run_comparative_benchmark(self):
        """Run comparative benchmark between Verilator and NVC."""

        print("Verilator vs NVC Comparative Benchmark")
        print("=" * 50)

        self.create_test_circuits()

        results = {}

        for circuit_name in self.test_circuits.keys():
            print(f"\\nTesting {circuit_name}...")
            print("-" * 30)

            # Run multiple iterations for statistical significance
            verilator_times = []
            nvc_times = []

            for run in range(3):
                print(f"Run {run + 1}/3:")

                # Verilator benchmark
                vt = self.run_verilator_benchmark(circuit_name, circuit_name)
                if vt is not None:
                    verilator_times.append(vt)

                # NVC benchmark
                nt = self.run_nvc_benchmark(circuit_name, circuit_name)
                if nt is not None:
                    nvc_times.append(nt)

            if verilator_times and nvc_times:
                avg_verilator = statistics.mean(verilator_times)
                avg_nvc = statistics.mean(nvc_times)
                speedup = avg_nvc / avg_verilator

                results[circuit_name] = {
                    'verilator_avg': avg_verilator,
                    'nvc_avg': avg_nvc,
                    'speedup': speedup,
                    'cycles': self.test_circuits[circuit_name]['testbench_cycles']
                }

                print(f"\\n{circuit_name} Results:")
                print(f"  Verilator avg: {avg_verilator:.3f}s")
                print(f"  NVC avg:       {avg_nvc:.3f}s")
                if speedup > 1.0:
                    print(f"  Verilator {speedup:.1f}× FASTER")
                else:
                    print(f"  NVC {1/speedup:.1f}× FASTER")

        return results

    def print_summary(self, results):
        """Print benchmark summary."""

        print("\\n" + "=" * 50)
        print("BENCHMARK SUMMARY")
        print("=" * 50)

        if not results:
            print("No valid results obtained")
            return

        print(f"{'Circuit':<12} {'Verilator':<12} {'NVC':<12} {'Winner'}")
        print("-" * 50)

        verilator_wins = 0
        nvc_wins = 0

        for circuit, data in results.items():
            if data['speedup'] > 1.0:
                winner = f"Verilator {data['speedup']:.1f}×"
                verilator_wins += 1
            else:
                winner = f"NVC {1/data['speedup']:.1f}×"
                nvc_wins += 1

            print(f"{circuit:<12} {data['verilator_avg']:.3f}s     {data['nvc_avg']:.3f}s     {winner}")

        print("\\n" + "=" * 50)
        print("OVERALL RESULTS:")
        print(f"Verilator wins: {verilator_wins}")
        print(f"NVC wins: {nvc_wins}")

        if verilator_wins > nvc_wins:
            print("🏆 Verilator is faster overall")
        elif nvc_wins > verilator_wins:
            print("🏆 NVC is faster overall")
        else:
            print("🤝 Performance is competitive")

def main():
    """Run the benchmark."""

    # Check if tools are available
    print("Checking tool availability...")

    try:
        subprocess.run(["verilator", "--version"], capture_output=True, timeout=5)
        print("✓ Verilator available")
    except:
        print("✗ Verilator not found")
        return

    try:
        subprocess.run(["nvc", "--version"], capture_output=True, timeout=5)
        print("✓ NVC available")
    except:
        print("✗ NVC not found")
        return

    benchmark = VerilatorNvcBenchmark()
    results = benchmark.run_comparative_benchmark()
    benchmark.print_summary(results)

if __name__ == "__main__":
    main()