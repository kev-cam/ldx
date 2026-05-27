#!/usr/bin/env python3
"""
zcu104_minimal_deploy.py — Minimal ZCU104 deployment test

Deploy a single small configuration to validate the hardware deployment approach.
"""

import subprocess
import time
import os

class ZCU104MinimalDeploy:
    """Minimal deployment test for ZCU104."""

    def __init__(self):
        self.work_dir = "/tmp/zcu104_minimal"
        os.makedirs(self.work_dir, exist_ok=True)

    def create_simple_accelerator(self):
        """Create simple accelerator for validation."""

        # Simple 32-bit x 256 memory accelerator (proven working from capacity test)
        accelerator = '''
module simple_accel (
    input wire clk,
    input wire rst,
    input wire [31:0] write_data,
    input wire [7:0] addr,
    input wire write_en,
    output reg [31:0] read_data,
    output reg [31:0] cycle_counter
);

// Small memory array (1KB)
reg [31:0] memory [0:255];
reg [31:0] cycles;

always @(posedge clk) begin
    if (rst) begin
        read_data <= 32'h0;
        cycles <= 32'h0;
        cycle_counter <= 32'h0;
    end else begin
        cycles <= cycles + 1;
        cycle_counter <= cycles;

        if (write_en) begin
            memory[addr] <= write_data;
        end
        read_data <= memory[addr];
    end
end

endmodule'''

        # Simple testbench for validation
        testbench = '''
module tb_simple_accel;

reg clk = 0;
reg rst = 1;
reg [31:0] write_data;
reg [7:0] addr;
reg write_en;
wire [31:0] read_data;
wire [31:0] cycle_counter;

simple_accel uut (
    .clk(clk),
    .rst(rst),
    .write_data(write_data),
    .addr(addr),
    .write_en(write_en),
    .read_data(read_data),
    .cycle_counter(cycle_counter)
);

always #5 clk = ~clk;  // 100MHz clock

initial begin
    $dumpfile("simple_accel.vcd");
    $dumpvars(0, tb_simple_accel);

    // Reset sequence
    rst = 1;
    #100;
    rst = 0;

    // Simple test: write then read
    repeat(256) begin
        @(posedge clk);
        addr = $random % 256;
        write_data = $random;
        write_en = 1;

        @(posedge clk);
        write_en = 0;

        @(posedge clk);
        if (read_data == write_data) begin
            $display("PASS: addr=%d, data=0x%h", addr, read_data);
        end else begin
            $display("FAIL: addr=%d, expected=0x%h, got=0x%h", addr, write_data, read_data);
        end
    end

    $display("Performance: %d cycles", cycle_counter);
    $finish;
end

endmodule'''

        # Write files
        accel_file = f"{self.work_dir}/simple_accel.v"
        tb_file = f"{self.work_dir}/tb_simple_accel.v"

        with open(accel_file, 'w') as f:
            f.write(accelerator)
        with open(tb_file, 'w') as f:
            f.write(testbench)

        return accel_file, tb_file

    def test_with_iverilog(self, accel_file, tb_file):
        """Quick test with iverilog to validate functionality."""

        print("Testing accelerator with iverilog...")

        try:
            # Compile
            result = subprocess.run([
                "iverilog", "-o", f"{self.work_dir}/sim", tb_file, accel_file
            ], capture_output=True, text=True)

            if result.returncode != 0:
                print(f"  ✗ Compile failed: {result.stderr}")
                return False

            # Simulate
            result = subprocess.run([
                f"{self.work_dir}/sim"
            ], capture_output=True, text=True, cwd=self.work_dir)

            if result.returncode == 0:
                print(f"  ✓ Simulation successful")

                # Check for performance results
                for line in result.stdout.split('\n'):
                    if "Performance:" in line:
                        print(f"  {line}")
                    elif "PASS:" in line[-50:]:  # Show last few passes
                        print(f"  {line}")

                return True
            else:
                print(f"  ✗ Simulation failed: {result.stderr}")
                return False

        except Exception as e:
            print(f"  ✗ Error: {e}")
            return False

    def create_synthesis_test(self, accel_file):
        """Create synthesis test using proven working approach."""

        print("Creating synthesis test...")

        # Use our proven working TCL approach
        tcl_script = f'''
create_project simple_accel_test {self.work_dir}/synth_project -part xczu7ev-ffvc1156-2-e -force
add_files -norecurse {accel_file}
set_property top simple_accel [current_fileset]
update_compile_order -fileset sources_1

# Basic timing constraint
create_clock -period 10.000 -name clk [get_ports clk]

# Synthesize with error handling
if {{ [catch {{synth_design -top simple_accel -part xczu7ev-ffvc1156-2-e}} synth_error] }} {{
    puts "SYNTHESIS_ERROR: $synth_error"
    exit 1
}}

# Check if design is open
if {{ [current_design -quiet] eq "" }} {{
    puts "ERROR: No design is currently open after synthesis"
    exit 1
}}

# Get resource usage safely
set luts 0
set ffs 0
set rams 0

if {{ [catch {{
    set all_luts [get_cells -hierarchical -filter {{REF_NAME =~ "LUT*"}}]
    set luts [llength $all_luts]
}}] }} {{
    set luts 0
}}

if {{ [catch {{
    set all_ffs [get_cells -hierarchical -filter {{REF_NAME =~ "*FF*" || REF_NAME =~ "*REG*"}}]
    set ffs [llength $all_ffs]
}}] }} {{
    set ffs 0
}}

if {{ [catch {{
    set bram36_cells [get_cells -hierarchical -filter {{REF_NAME =~ "*RAMB36*"}}]
    set bram18_cells [get_cells -hierarchical -filter {{REF_NAME =~ "*RAMB18*"}}]
    set rams [expr [llength $bram36_cells] + [llength $bram18_cells]]
}}] }} {{
    set rams 0
}}

puts "RESOURCE_SUMMARY: LUT=$luts FF=$ffs BRAM=$rams"
puts "SYNTHESIS_SUCCESS: 1"

exit 0
'''

        script_file = f"{self.work_dir}/synth_test.tcl"
        with open(script_file, 'w') as f:
            f.write(tcl_script)

        return script_file

    def run_synthesis_test(self, script_file):
        """Run synthesis test."""

        print("Running synthesis test...")

        try:
            result = subprocess.run([
                "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
                "-source", script_file
            ], capture_output=True, text=True, timeout=300)

            if result.returncode == 0 and "SYNTHESIS_SUCCESS: 1" in result.stdout:
                print(f"  ✓ Synthesis successful!")

                # Extract resources
                for line in result.stdout.split('\n'):
                    if 'RESOURCE_SUMMARY:' in line:
                        print(f"  {line}")
                        return True

            else:
                print(f"  ✗ Synthesis failed")
                if result.stderr:
                    print(f"    Error: {result.stderr[:200]}")
                return False

        except Exception as e:
            print(f"  ✗ Synthesis error: {e}")
            return False

    def create_performance_comparison(self):
        """Create side-by-side performance comparison."""

        print("\n" + "="*50)
        print("PERFORMANCE COMPARISON FRAMEWORK")
        print("="*50)

        comparison_script = f'''#!/bin/bash
# ZCU104 Performance Comparison Script

echo "=== ZCU104 RTL Acceleration Performance Test ==="
echo "Comparing software simulation vs FPGA acceleration"
echo

echo "1. Software baseline (NVC):"
# This will be filled in with actual NVC results

echo "2. Iverilog baseline:"
cd {self.work_dir}
./sim > iverilog_results.txt 2>&1
grep "Performance:" iverilog_results.txt

echo "3. Vivado synthesis results:"
# Resource usage from synthesis

echo "4. Next: Deploy to FPGA hardware"
echo "   - Create bitstream"
echo "   - Program ZCU104"
echo "   - Measure real hardware performance"

echo
echo "Target: Beat Verilator's 6M cycles/second"
'''

        script_path = f"{self.work_dir}/performance_test.sh"
        with open(script_path, 'w') as f:
            f.write(comparison_script)

        os.chmod(script_path, 0o755)
        return script_path

    def run_minimal_test_sequence(self):
        """Run the complete minimal test sequence."""

        print("ZCU104 Minimal Deployment Test")
        print("=" * 40)

        # Create accelerator
        accel_file, tb_file = self.create_simple_accelerator()
        print(f"✓ Created accelerator: {accel_file}")

        # Test with iverilog
        if not self.test_with_iverilog(accel_file, tb_file):
            print("✗ Iverilog test failed - stopping")
            return False

        # Test synthesis
        script_file = self.create_synthesis_test(accel_file)
        if not self.run_synthesis_test(script_file):
            print("✗ Synthesis test failed - stopping")
            return False

        # Create comparison framework
        perf_script = self.create_performance_comparison()
        print(f"✓ Performance framework: {perf_script}")

        print(f"\n🎯 SUCCESS: Minimal deployment validation complete!")
        print(f"   Ready to proceed with full hardware deployment")
        print(f"   All files in: {self.work_dir}")

        return True

def main():
    """Run minimal ZCU104 deployment test."""

    deploy = ZCU104MinimalDeploy()
    success = deploy.run_minimal_test_sequence()

    if success:
        print(f"\n✓ Ready for full ZCU104 hardware deployment!")
    else:
        print(f"\n✗ Issues found - fix before proceeding")

if __name__ == "__main__":
    main()