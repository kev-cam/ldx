#!/usr/bin/env python3
"""
working_capacity_test.py — Working ZCU104 capacity test using proven TCL approach
"""

import subprocess
import time
import os
import json

def test_config_synthesis(name, width, depth, mem_type, work_dir):
    """Test synthesis for a single configuration using proven approach."""

    print(f"Testing {name}: {width}-bit x {depth} {mem_type}")

    # Generate simple Verilog (same as test_synthesis_fix.py)
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

    elif mem_type == "fifo":
        verilog = f'''
module {module_name} (
    input wire clk,
    input wire rst,
    input wire [{width-1}:0] data_in,
    input wire push,
    input wire pop,
    output reg [{width-1}:0] data_out,
    output reg empty,
    output reg full
);

reg [{width-1}:0] fifo_mem [0:{depth-1}];
reg [{addr_bits:0}] write_ptr;
reg [{addr_bits:0}] read_ptr;

always @(posedge clk) begin
    if (rst) begin
        write_ptr <= 0;
        read_ptr <= 0;
        data_out <= {width}'h0;
        empty <= 1'b1;
        full <= 1'b0;
    end else begin
        if (push && !full) begin
            fifo_mem[write_ptr[{addr_bits-1}:0]] <= data_in;
            write_ptr <= write_ptr + 1;
        end
        if (pop && !empty) begin
            data_out <= fifo_mem[read_ptr[{addr_bits-1}:0]];
            read_ptr <= read_ptr + 1;
        end
        empty <= (write_ptr == read_ptr);
        full <= ((write_ptr + 1) == read_ptr);
    end
end

endmodule'''

    # Write Verilog file
    verilog_file = f"{work_dir}/{module_name}.v"
    with open(verilog_file, 'w') as f:
        f.write(verilog)

    # Create TCL script (exact same as working test_synthesis_fix.py)
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
        ], capture_output=True, text=True, timeout=180)

        if result.returncode == 0 and "SYNTHESIS_SUCCESS: 1" in result.stdout:
            # Parse results
            luts, ffs, brams = 0, 0, 0
            for line in result.stdout.split('\n'):
                if 'RESOURCE_SUMMARY:' in line:
                    parts = line.split(':')[1].strip().split()
                    for part in parts:
                        if '=' in part:
                            key, val = part.split('=')
                            if key == 'LUT':
                                luts = int(val) if val.isdigit() else 0
                            elif key == 'FF':
                                ffs = int(val) if val.isdigit() else 0
                            elif key == 'BRAM':
                                brams = int(val) if val.isdigit() else 0

            # Calculate memory size
            memory_kb = (width * depth) / 8192

            # Check if fits (simple heuristic)
            lut_util = luts / 504000.0
            ff_util = ffs / 1008000.0
            bram_util = brams / 912.0
            fits = lut_util < 0.8 and ff_util < 0.8 and bram_util < 0.8

            status = "✓ FITS" if fits else "✗ TOO BIG"
            print(f"  {status} - {memory_kb:.1f}KB, LUTs: {luts}, FFs: {ffs}, BRAMs: {brams}")

            return {
                'width': width, 'depth': depth, 'type': mem_type,
                'memory_kb': memory_kb, 'synthesis_success': True,
                'luts': luts, 'ffs': ffs, 'brams': brams,
                'utilization': {'lut': lut_util, 'ff': ff_util, 'bram': bram_util},
                'fits_on_zcu104': fits
            }
        else:
            print(f"  ✗ SYNTHESIS FAILED")
            if result.stderr:
                print(f"    Error: {result.stderr[:100]}...")
            return {'synthesis_success': False, 'fits_on_zcu104': False}

    except Exception as e:
        print(f"  ✗ ERROR: {e}")
        return {'synthesis_success': False, 'fits_on_zcu104': False}

def main():
    """Run practical ZCU104 capacity tests."""

    print("ZCU104 Memory Capacity Test (Working Version)")
    print("=" * 50)

    work_dir = "/tmp/working_capacity_test"
    os.makedirs(work_dir, exist_ok=True)

    # Test practical configurations
    configs = [
        # Small configs first
        ("small_mem_8x256", 8, 256, "memory"),
        ("small_mem_16x512", 16, 512, "memory"),
        ("reg_file_32x32", 32, 32, "register_file"),
        ("reg_file_32x64", 32, 64, "register_file"),

        # Medium configs
        ("med_mem_32x1k", 32, 1024, "memory"),
        ("med_mem_32x2k", 32, 2048, "memory"),
        ("wide_mem_64x1k", 64, 1024, "memory"),
        ("fifo_32x512", 32, 512, "fifo"),

        # Large configs
        ("large_mem_32x4k", 32, 4096, "memory"),
        ("large_mem_32x8k", 32, 8192, "memory"),
        ("huge_mem_32x16k", 32, 16384, "memory"),
        ("ultra_wide_128x1k", 128, 1024, "memory"),
    ]

    results = {}
    successful = 0

    print(f"Testing {len(configs)} practical memory configurations...")
    print()

    for name, width, depth, mem_type in configs:
        result = test_config_synthesis(name, width, depth, mem_type, work_dir)
        results[name] = result

        if result.get('synthesis_success', False):
            successful += 1
            if result.get('fits_on_zcu104', False):
                print(f"    → Can use for RTL acceleration")
            else:
                print(f"    → Too large for single ZCU104")
        print()

    print("=" * 50)
    print("RESULTS SUMMARY")
    print("=" * 50)
    print(f"Total tested: {len(configs)}")
    print(f"Successful synthesis: {successful}")
    print(f"Failed synthesis: {len(configs) - successful}")

    # Find largest working configurations
    working = {k: v for k, v in results.items()
               if v.get('synthesis_success', False) and v.get('fits_on_zcu104', False)}

    if working:
        print(f"\nConfigurations that FIT on ZCU104:")
        for name, data in working.items():
            print(f"  {name}: {data['memory_kb']:.1f}KB ({data['luts']} LUTs, {data['brams']} BRAMs)")

        # Find sweet spots
        largest_mem = max((v for k, v in working.items() if v['type'] == 'memory'),
                         key=lambda x: x['memory_kb'], default=None)
        if largest_mem:
            print(f"\n🎯 Largest working memory: {largest_mem['memory_kb']:.1f}KB")

    # Save results
    with open(f"{work_dir}/capacity_results.json", 'w') as f:
        json.dump(results, f, indent=2)

    print(f"\n📊 Results saved to: {work_dir}/capacity_results.json")

    if successful > 0:
        print(f"\n✓ SUCCESS: Synthesis working, can proceed with full benchmarks!")
        return True
    else:
        print(f"\n✗ All synthesis failed - need to investigate Vivado setup")
        return False

if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)