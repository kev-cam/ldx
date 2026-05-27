#!/usr/bin/env python3
"""
test_synthesis_fix.py — Test the fixed Vivado synthesis scripts with small configs
"""

import subprocess
import time
import os

def test_small_synthesis():
    """Test synthesis on a few small configurations to verify the fix."""

    print("Testing Vivado synthesis fix...")
    print("=" * 40)

    # Simple test configurations
    configs = [
        ("small_mem", 8, 256, "memory", "Small 8-bit x 256 memory"),
        ("reg_file", 32, 32, "register_file", "Standard 32x32 register file"),
        ("shift_reg", 16, 64, "shift_reg", "16-bit x 64 shift register")
    ]

    work_dir = "/tmp/synthesis_test"
    os.makedirs(work_dir, exist_ok=True)

    for name, width, depth, mem_type, desc in configs:
        print(f"\nTesting {name}: {desc}")

        result = test_config_synthesis(name, width, depth, mem_type, work_dir)
        if result:
            print(f"  ✓ SUCCESS: {result}")
        else:
            print(f"  ✗ FAILED")

def test_config_synthesis(name, width, depth, mem_type, work_dir):
    """Test synthesis for a single configuration."""

    # Generate simple Verilog
    addr_bits = max(1, (depth - 1).bit_length())
    module_name = f"test_{name}"

    if mem_type == "memory":
        verilog = f'''
module {module_name} (
    input wire clk,
    input wire rst,
    input wire [{width-1}:0] data_in,
    input wire [{addr_bits-1}:0] addr,
    input wire write_en,
    output reg [{width-1}:0] data_out
);

reg [{width-1}:0] memory [0:{depth-1}];

always @(posedge clk) begin
    if (rst) begin
        data_out <= {width}'h0;
    end else begin
        if (write_en) begin
            memory[addr] <= data_in;
        end
        data_out <= memory[addr];
    end
end

endmodule'''

    elif mem_type == "register_file":
        verilog = f'''
module {module_name} (
    input wire clk,
    input wire rst,
    input wire [{width-1}:0] write_data,
    input wire [{addr_bits-1}:0] write_addr,
    input wire [{addr_bits-1}:0] read_addr_a,
    input wire [{addr_bits-1}:0] read_addr_b,
    input wire write_en,
    output reg [{width-1}:0] read_data_a,
    output reg [{width-1}:0] read_data_b
);

reg [{width-1}:0] registers [0:{depth-1}];

always @(posedge clk) begin
    if (rst) begin
        read_data_a <= {width}'h0;
        read_data_b <= {width}'h0;
    end else begin
        if (write_en && write_addr != 0) begin
            registers[write_addr] <= write_data;
        end
        read_data_a <= (read_addr_a == 0) ? {width}'h0 : registers[read_addr_a];
        read_data_b <= (read_addr_b == 0) ? {width}'h0 : registers[read_addr_b];
    end
end

endmodule'''

    elif mem_type == "shift_reg":
        verilog = f'''
module {module_name} (
    input wire clk,
    input wire rst,
    input wire [{width-1}:0] data_in,
    input wire shift_en,
    output wire [{width-1}:0] data_out
);

reg [{width-1}:0] shift_stages [0:{depth-1}];
integer i;

always @(posedge clk) begin
    if (rst) begin
        for (i = 0; i < {depth}; i = i + 1) begin
            shift_stages[i] <= {width}'h0;
        end
    end else if (shift_en) begin
        shift_stages[0] <= data_in;
        for (i = 1; i < {depth}; i = i + 1) begin
            shift_stages[i] <= shift_stages[i-1];
        end
    end
end

assign data_out = shift_stages[{depth-1}];

endmodule'''

    # Write Verilog file
    verilog_file = f"{work_dir}/{module_name}.v"
    with open(verilog_file, 'w') as f:
        f.write(verilog)

    # Create fixed TCL script
    synth_script = f'''
create_project {module_name} {work_dir}/{module_name}_project -part xczu7ev-ffvc1156-2-e -force
add_files -norecurse {verilog_file}
set_property top {module_name} [current_fileset]
update_compile_order -fileset sources_1

# Synthesize with error handling
if {{ [catch {{synth_design -top {module_name} -part xczu7ev-ffvc1156-2-e}} synth_error] }} {{
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

    script_file = f"{work_dir}/synth_{module_name}.tcl"
    with open(script_file, 'w') as f:
        f.write(synth_script)

    # Run synthesis
    try:
        result = subprocess.run([
            "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
            "-source", script_file
        ], capture_output=True, text=True, timeout=120)

        if result.returncode == 0 and "SYNTHESIS_SUCCESS: 1" in result.stdout:
            # Extract results
            for line in result.stdout.split('\n'):
                if 'RESOURCE_SUMMARY:' in line:
                    return line.split(':')[1].strip()
            return "Success (no resource info)"
        else:
            print(f"    Error output: {result.stderr[:200]}")
            return None

    except Exception as e:
        print(f"    Exception: {e}")
        return None

if __name__ == "__main__":
    test_small_synthesis()