#!/usr/bin/env python3
"""
zcu104_memory_capacity_test.py — Quick test of practical memory sizes for ZCU104

Tests realistic memory configurations that would be used in RTL simulation
acceleration to determine capacity limits and performance characteristics.
"""

import subprocess
import time
import os
import json

class ZCU104CapacityTest:
    """Quick capacity test for practical memory configurations."""

    def __init__(self):
        self.test_configs = self.generate_practical_configs()
        self.results = {}

    def generate_practical_configs(self):
        """Generate practical memory configurations for RTL simulation."""

        # Based on common RTL simulation needs
        configs = {
            # Register files (common in processors)
            'reg_file_32x32': (32, 32, 'register_file', "32-bit register file (32 registers)"),
            'reg_file_32x256': (32, 256, 'register_file', "Large register file (256 registers)"),

            # Instruction/data memories
            'imem_32x1k': (32, 1024, 'memory', "Instruction memory 4KB"),
            'imem_32x4k': (32, 4096, 'memory', "Instruction memory 16KB"),
            'dmem_32x8k': (32, 8192, 'memory', "Data memory 32KB"),
            'dmem_64x4k': (64, 4096, 'memory', "Wide data memory 32KB"),

            # Cache memories
            'cache_line_128x512': (128, 512, 'memory', "Cache line storage 8KB"),
            'cache_tag_32x1k': (32, 1024, 'memory', "Cache tag array 4KB"),

            # Large arrays (stress test)
            'large_mem_32x16k': (32, 16384, 'memory', "Large memory 64KB"),
            'large_mem_32x32k': (32, 32768, 'memory', "Very large memory 128KB"),
            'wide_mem_256x1k': (256, 1024, 'memory', "Ultra-wide memory 32KB"),

            # FIFO/Buffers
            'fifo_32x512': (32, 512, 'fifo', "Standard FIFO buffer 2KB"),
            'fifo_64x256': (64, 256, 'fifo', "Wide FIFO buffer 2KB"),

            # Specialized arrays
            'lookup_table_16x4k': (16, 4096, 'memory', "Lookup table 8KB"),
            'shift_reg_32x128': (32, 128, 'shift_reg', "Deep shift register"),
        }

        return configs

    def create_test_module(self, width, depth, mem_type, name):
        """Create Verilog test module for the configuration."""

        addr_bits = max(1, (depth - 1).bit_length())

        if mem_type == 'memory':
            verilog = f'''
module test_{name} (
    input wire clk,
    input wire rst,
    input wire [{width-1}:0] data_in,
    input wire [{addr_bits-1}:0] addr,
    input wire write_en,
    output reg [{width-1}:0] data_out
);

// Memory array - will infer BRAM for larger sizes
reg [{width-1}:0] memory [0:{depth-1}];

always @(posedge clk) begin
    if (rst) begin
        data_out <= {{{width}{{1'b0}}}};
    end else begin
        if (write_en) begin
            memory[addr] <= data_in;
        end
        data_out <= memory[addr];
    end
end

// Estimated size: {width * depth} bits = {width * depth // 8} bytes

endmodule'''

        elif mem_type == 'fifo':
            verilog = f'''
module test_{name} (
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
wire [{addr_bits:0}] next_write = write_ptr + 1;
wire [{addr_bits:0}] next_read = read_ptr + 1;

always @(posedge clk) begin
    if (rst) begin
        write_ptr <= 0;
        read_ptr <= 0;
        data_out <= {{{width}{{1'b0}}}};
        empty <= 1'b1;
        full <= 1'b0;
    end else begin
        if (push && !full) begin
            fifo_mem[write_ptr[{addr_bits-1}:0]] <= data_in;
            write_ptr <= next_write;
        end

        if (pop && !empty) begin
            data_out <= fifo_mem[read_ptr[{addr_bits-1}:0]];
            read_ptr <= next_read;
        end

        empty <= (write_ptr == read_ptr);
        full <= (next_write == read_ptr);
    end
end

endmodule'''

        elif mem_type == 'register_file':
            rd_addr_bits = addr_bits
            verilog = f'''
module test_{name} (
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
        read_data_a <= {{{width}{{1'b0}}}};
        read_data_b <= {{{width}{{1'b0}}}};
    end else begin
        if (write_en && write_addr != 0) begin  // Don't write to register 0
            registers[write_addr] <= write_data;
        end

        read_data_a <= (read_addr_a == 0) ? {{{width}{{1'b0}}}} : registers[read_addr_a];
        read_data_b <= (read_addr_b == 0) ? {{{width}{{1'b0}}}} : registers[read_addr_b];
    end
end

endmodule'''

        elif mem_type == 'shift_reg':
            verilog = f'''
module test_{name} (
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
            shift_stages[i] <= {{{width}{{1'b0}}}};
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

        return verilog

    def quick_synthesis_test(self, config_name, width, depth, mem_type, description):
        """Quick synthesis test to check if configuration fits."""

        print(f"Testing {config_name}: {description}")

        # Create module
        module_name = f"test_{config_name}"
        verilog_code = self.create_test_module(width, depth, mem_type, config_name)

        verilog_file = f"/tmp/{module_name}.v"
        with open(verilog_file, 'w') as f:
            f.write(verilog_code)

        # Quick synthesis test
        synth_script = f'''
create_project {module_name} /tmp/{module_name}_proj -part xczu7ev-ffvc1156-2-e -force
add_files {verilog_file}
set_property top {module_name} [current_fileset]
update_compile_order -fileset sources_1

# Synthesize with error handling
if {{ [catch {{synth_design -top {module_name} -part xczu7ev-ffvc1156-2-e}} synth_error] }} {{
    puts "SYNTHESIS_ERROR: $synth_error"
    puts "FITS: 0"
    exit 1
}}

# Check if design is open
if {{ [current_design -quiet] eq "" }} {{
    puts "ERROR: No design is currently open after synthesis"
    puts "FITS: 0"
    exit 1
}}

# Get resource usage safely
set luts 0
set ffs 0
set rams 0

if {{ [catch {{
    # Try to get actual resource counts
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

puts "RESOURCES: LUT=$luts FF=$ffs BRAM=$rams"

# Check if it fits (rough estimate)
set lut_util [expr $luts / 504000.0]
set ff_util [expr $ffs / 1008000.0]
set bram_util [expr $rams / 912.0]

set fits [expr $lut_util < 0.8 && $ff_util < 0.8 && $bram_util < 0.8]
puts "UTILIZATION: LUT=[format %.3f $lut_util] FF=[format %.3f $ff_util] BRAM=[format %.3f $bram_util]"
puts "FITS: $fits"

exit 0
'''

        script_file = f"/tmp/synth_{config_name}.tcl"
        with open(script_file, 'w') as f:
            f.write(synth_script)

        try:
            result = subprocess.run([
                "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
                "-source", script_file
            ], capture_output=True, text=True, timeout=300)

            if result.returncode == 0:
                # Parse results
                resources = {'luts': 0, 'ffs': 0, 'brams': 0}
                utilization = {'lut_util': 0, 'ff_util': 0, 'bram_util': 0}
                fits = False

                for line in result.stdout.split('\\n'):
                    if 'RESOURCES:' in line:
                        parts = line.split(':')[1].split()
                        for part in parts:
                            if '=' in part:
                                key, val = part.split('=')
                                if key == 'LUT':
                                    resources['luts'] = int(val)
                                elif key == 'FF':
                                    resources['ffs'] = int(val)
                                elif key == 'BRAM':
                                    resources['brams'] = int(val)

                    if 'UTILIZATION:' in line:
                        parts = line.split(':')[1]
                        # Extract utilization values
                        import re
                        lut_match = re.search(r'LUT=([0-9.]+)', parts)
                        ff_match = re.search(r'FF=([0-9.]+)', parts)
                        bram_match = re.search(r'BRAM=([0-9.]+)', parts)

                        if lut_match:
                            utilization['lut_util'] = float(lut_match.group(1))
                        if ff_match:
                            utilization['ff_util'] = float(ff_match.group(1))
                        if bram_match:
                            utilization['bram_util'] = float(bram_match.group(1))

                    if 'FITS:' in line:
                        fits = '1' in line.split(':')[1]

                # Calculate memory size
                memory_bits = width * depth
                memory_kb = memory_bits / 8192

                result_data = {
                    'width': width,
                    'depth': depth,
                    'type': mem_type,
                    'description': description,
                    'memory_kb': memory_kb,
                    'synthesis_success': True,
                    'resources': resources,
                    'utilization': utilization,
                    'fits_on_zcu104': fits
                }

                status = "✓ FITS" if fits else "✗ TOO BIG"
                print(f"  {status} - {memory_kb:.1f}KB, LUTs: {resources['luts']}, BRAMs: {resources['brams']}")

                return result_data

            else:
                print(f"  ✗ SYNTHESIS FAILED")
                return {
                    'synthesis_success': False,
                    'fits_on_zcu104': False,
                    'error': result.stderr
                }

        except Exception as e:
            print(f"  ✗ ERROR: {e}")
            return {
                'synthesis_success': False,
                'fits_on_zcu104': False,
                'error': str(e)
            }

    def run_capacity_tests(self):
        """Run all capacity tests."""

        print("ZCU104 Memory Capacity Test")
        print("=" * 40)
        print("Testing practical RTL simulation memory configurations")
        print()

        for config_name, (width, depth, mem_type, desc) in self.test_configs.items():
            result = self.quick_synthesis_test(config_name, width, depth, mem_type, desc)
            self.results[config_name] = result
            time.sleep(1)  # Brief pause between tests

    def generate_capacity_report(self):
        """Generate capacity analysis report."""

        print("\\n" + "=" * 60)
        print("ZCU104 MEMORY CAPACITY REPORT")
        print("=" * 60)

        # Successful configurations
        successful = {k: v for k, v in self.results.items()
                     if v.get('synthesis_success', False) and v.get('fits_on_zcu104', False)}
        failed = {k: v for k, v in self.results.items()
                 if not (v.get('synthesis_success', False) and v.get('fits_on_zcu104', False))}

        print(f"\\nResults Summary:")
        print(f"  Total configurations tested: {len(self.results)}")
        print(f"  Successful (fits on ZCU104): {len(successful)}")
        print(f"  Failed or too large: {len(failed)}")

        if successful:
            print(f"\\nConfigurations that FIT on ZCU104:")
            print(f"{'Config':<20} {'Type':<12} {'Size':<15} {'Memory':<10} {'BRAMs':<8}")
            print("-" * 70)

            for name, data in successful.items():
                if 'memory_kb' in data:
                    size_str = f"{data['width']}×{data['depth']}"
                    mem_str = f"{data['memory_kb']:.1f}KB"
                    brams = data['resources'].get('brams', 0)
                    print(f"{name:<20} {data['type']:<12} {size_str:<15} {mem_str:<10} {brams:<8}")

        if failed:
            print(f"\\nConfigurations that DON'T FIT:")
            for name, data in failed.items():
                if data.get('synthesis_success', False):
                    print(f"  {name}: Too large for ZCU104")
                else:
                    print(f"  {name}: Synthesis failed")

        # Find sweet spots
        if successful:
            print(f"\\n🎯 SWEET SPOTS:")

            # Largest successful memory
            memories = {k: v for k, v in successful.items() if v['type'] == 'memory'}
            if memories:
                largest = max(memories.items(), key=lambda x: x[1]['memory_kb'])
                print(f"  Largest memory: {largest[0]} ({largest[1]['memory_kb']:.1f}KB)")

            # Most efficient (lowest resource usage)
            if len(successful) > 1:
                most_efficient = min(successful.items(),
                                   key=lambda x: x[1]['utilization']['lut_util'])
                print(f"  Most efficient: {most_efficient[0]} "
                      f"({most_efficient[1]['utilization']['lut_util']:.1%} LUT utilization)")

        # Save results
        with open('/tmp/zcu104_capacity_results.json', 'w') as f:
            json.dump(self.results, f, indent=2)

        print(f"\\n📊 Detailed results saved to: /tmp/zcu104_capacity_results.json")

def main():
    """Run ZCU104 capacity test."""

    tester = ZCU104CapacityTest()
    tester.run_capacity_tests()
    tester.generate_capacity_report()

    print(f"\\n🎯 PRACTICAL CONCLUSIONS:")
    print(f"This test shows realistic memory sizes for RTL simulation:")
    print(f"  • What array sizes work on ZCU104")
    print(f"  • Resource usage for common configurations")
    print(f"  • Sweet spots for different memory types")
    print(f"  • Basis for scaling up to multiple FPGAs")

if __name__ == "__main__":
    main()