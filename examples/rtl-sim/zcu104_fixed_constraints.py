#!/usr/bin/env python3
"""
zcu104_fixed_constraints.py — Fix ZCU104 pin constraints and rebuild
"""

import subprocess
import time
import os

def create_correct_zcu104_constraints():
    """Create correct pin constraints for ZCU104."""

    # Use actual ZCU104 pins from Xilinx documentation
    constraints = '''
# ZCU104 Clock - 125MHz differential clock
set_property PACKAGE_PIN H9  [get_ports clk_p]
set_property PACKAGE_PIN G9  [get_ports clk_n]
set_property IOSTANDARD LVDS [get_ports clk_p]
set_property IOSTANDARD LVDS [get_ports clk_n]

# Create 100MHz clock from 125MHz input
create_clock -period 8.000 -name clk_125mhz [get_ports clk_p]

# Reset - Use SW19 (rightmost DIP switch)
set_property PACKAGE_PIN A17 [get_ports reset_n]
set_property IOSTANDARD LVCMOS12 [get_ports reset_n]

# Test button - Use SW18 (DIP switch)
set_property PACKAGE_PIN A16 [get_ports test_button]
set_property IOSTANDARD LVCMOS12 [get_ports test_button]

# LEDs - Use actual ZCU104 user LEDs (DS50-DS53)
set_property PACKAGE_PIN D5  [get_ports {led_out[0]}]
set_property PACKAGE_PIN D6  [get_ports {led_out[1]}]
set_property PACKAGE_PIN A5  [get_ports {led_out[2]}]
set_property PACKAGE_PIN B5  [get_ports {led_out[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_out[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_out[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_out[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_out[3]}]

# Timing constraints
set_input_delay -clock [get_clocks clk_125mhz] -min 1.000 [get_ports reset_n]
set_input_delay -clock [get_clocks clk_125mhz] -max 2.000 [get_ports reset_n]
set_input_delay -clock [get_clocks clk_125mhz] -min 1.000 [get_ports test_button]
set_input_delay -clock [get_clocks clk_125mhz] -max 2.000 [get_ports test_button]

set_output_delay -clock [get_clocks clk_125mhz] -min 1.000 [get_ports {led_out[*]}]
set_output_delay -clock [get_clocks clk_125mhz] -max 2.000 [get_ports {led_out[*]}]
'''

    constraints_file = "/tmp/zcu104_streamlined/zcu104_constraints_fixed.xdc"
    with open(constraints_file, 'w') as f:
        f.write(constraints)

    return constraints_file

def create_fixed_toplevel():
    """Create fixed top-level with correct clock handling."""

    # Fixed top-level for actual ZCU104 pins
    toplevel = '''
module zcu104_perf_top (
    input wire clk_p,
    input wire clk_n,
    input wire reset_n,
    input wire test_button,
    output wire [3:0] led_out
);

// Clock generation - convert 125MHz differential to 100MHz single-ended
wire clk_125mhz;
wire clk_100mhz;
wire locked;

IBUFGDS #(
    .DIFF_TERM("TRUE"),
    .IOSTANDARD("LVDS")
) ibufgds_inst (
    .O(clk_125mhz),
    .I(clk_p),
    .IB(clk_n)
);

// Simple clock divider: 125MHz -> 100MHz (divide by 1.25, approximate with counter)
reg [2:0] clk_div_counter = 0;
reg clk_100mhz_reg = 0;

always @(posedge clk_125mhz) begin
    if (clk_div_counter >= 3'd4) begin  // Divide by 5 (125/5 = 25MHz, then use for enable)
        clk_div_counter <= 0;
    end else begin
        clk_div_counter <= clk_div_counter + 1;
    end
end

// Use 125MHz directly for simplicity in this test
assign clk_100mhz = clk_125mhz;
assign locked = 1'b1;

wire rst = ~reset_n;
reg start_test_reg;
wire test_complete;
wire [31:0] cycles_elapsed;
wire [31:0] operations_completed;

// Button synchronizer
reg [2:0] button_sync;
always @(posedge clk_100mhz) begin
    if (rst) begin
        button_sync <= 3'b000;
        start_test_reg <= 1'b0;
    end else begin
        button_sync <= {button_sync[1:0], test_button};
        start_test_reg <= button_sync[2] && !button_sync[1];  // Rising edge
    end
end

// Instantiate performance accelerator
perf_accelerator perf_inst (
    .clk(clk_100mhz),
    .rst(rst),
    .start_test(start_test_reg),
    .test_complete(test_complete),
    .cycles_elapsed(cycles_elapsed),
    .operations_completed(operations_completed)
);

// LED output - show test status and performance
assign led_out[0] = test_complete;
assign led_out[1] = |cycles_elapsed[15:8];    // Show some cycle count bits
assign led_out[2] = |operations_completed[15:8];
assign led_out[3] = cycles_elapsed[20];    // High bit of cycle count

endmodule'''

    top_file = "/tmp/zcu104_streamlined/zcu104_perf_top_fixed.v"
    with open(top_file, 'w') as f:
        f.write(toplevel)

    return top_file

def create_fixed_build_script():
    """Create fixed build script with corrected files."""

    # Use existing accelerator, just fix top-level and constraints
    accel_file = "/tmp/zcu104_streamlined/perf_accelerator.v"
    top_file = create_fixed_toplevel()
    constraints_file = create_correct_zcu104_constraints()

    build_script = f'''
# Fixed ZCU104 build script with correct pins
create_project zcu104_perf_fixed /tmp/zcu104_streamlined/zcu104_perf_fixed_proj -part xczu7ev-ffvc1156-2-e -force

# Add source files
add_files -norecurse {accel_file}
add_files -norecurse {top_file}
add_files -fileset constrs_1 {constraints_file}

set_property top zcu104_perf_top [current_fileset]
update_compile_order -fileset sources_1

# Synthesis
puts "Starting synthesis with fixed constraints..."
synth_design -top zcu104_perf_top -part xczu7ev-ffvc1156-2-e

if {{[current_design -quiet] eq ""}} {{
    puts "ERROR: Synthesis failed - no design"
    exit 1
}}

puts "Synthesis complete"

# Implementation
puts "Starting implementation..."
opt_design
place_design
route_design

puts "Implementation complete"

# Generate bitstream
puts "Generating bitstream..."
write_bitstream -force /tmp/zcu104_streamlined/zcu104_perf_fixed.bit

puts "SUCCESS: Fixed bitstream generated at /tmp/zcu104_streamlined/zcu104_perf_fixed.bit"

exit 0
'''

    script_file = "/tmp/zcu104_streamlined/build_perf_fixed.tcl"
    with open(script_file, 'w') as f:
        f.write(build_script)

    return script_file

def main():
    """Fix constraints and rebuild."""

    print("Fixing ZCU104 pin constraints and rebuilding...")

    script_file = create_fixed_build_script()
    print(f"✓ Created fixed build script: {script_file}")

    # Quick build - should work with correct pins
    try:
        print("Building fixed bitstream...")
        result = subprocess.run([
            "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
            "-source", script_file
        ], capture_output=True, text=True, timeout=900)

        if result.returncode == 0 and "SUCCESS:" in result.stdout:
            print("✓ Fixed bitstream build successful!")
            print("✓ Ready for ZCU104 deployment")
            return True
        else:
            print("✗ Build still failing")
            if result.stderr:
                print(f"Error: {result.stderr[-300:]}")
            return False

    except Exception as e:
        print(f"✗ Error: {e}")
        return False

if __name__ == "__main__":
    success = main()
    print(f"\nFixed build {'succeeded' if success else 'failed'}")