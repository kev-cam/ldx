#!/usr/bin/env python3
"""
fpga_build_system.py — Modular FPGA build system for RTL acceleration

Supports multiple FPGA targets with application-specific acceleration cores.
Extensible design for different synthesis acceleration modules.
"""

import os
import subprocess
import tempfile
import json
import shutil
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional

@dataclass
class FPGATarget:
    """FPGA target configuration."""
    name: str
    part: str
    board_part: Optional[str]
    vivado_board_files: Optional[str]
    clock_period_ns: float
    memory_size_mb: int
    max_cores: int

@dataclass
class AccelCore:
    """Application-specific acceleration core configuration."""
    name: str
    rtl_files: List[str]
    top_module: str
    parameters: Dict[str, str]
    memory_size_kb: int
    interfaces: List[str]

class FPGABuildSystem:
    """Modular FPGA build system."""

    # Supported FPGA targets
    FPGA_TARGETS = {
        'zcu104': FPGATarget(
            name='ZCU104',
            part='xczu7ev-ffvc1156-2-e',
            board_part='xilinx.com:zcu104:part0:1.1',
            vivado_board_files=None,
            clock_period_ns=10.0,  # 100 MHz
            memory_size_mb=4096,
            max_cores=64
        ),
        'zcu102': FPGATarget(
            name='ZCU102',
            part='xczu9eg-ffvb1156-2-e',
            board_part='xilinx.com:zcu102:part0:3.4',
            vivado_board_files=None,
            clock_period_ns=10.0,
            memory_size_mb=4096,
            max_cores=64
        ),
        'kcu105': FPGATarget(
            name='KCU105',
            part='xcku040-ffva1156-2-e',
            board_part='xilinx.com:kcu105:part0:1.7',
            vivado_board_files=None,
            clock_period_ns=5.0,   # 200 MHz
            memory_size_mb=512,
            max_cores=32
        )
    }

    def __init__(self, vivado_path="/opt/AMD/2025.2/Vivado/bin/vivado"):
        self.vivado_path = vivado_path
        self.work_dir = "/tmp/fpga_build"
        self.ensure_work_dir()

    def ensure_work_dir(self):
        """Create work directory structure."""
        os.makedirs(self.work_dir, exist_ok=True)
        os.makedirs(f"{self.work_dir}/rtl", exist_ok=True)
        os.makedirs(f"{self.work_dir}/constraints", exist_ok=True)
        os.makedirs(f"{self.work_dir}/tcl", exist_ok=True)
        os.makedirs(f"{self.work_dir}/results", exist_ok=True)

    def create_nvc_accel_core(self, core_count: int) -> AccelCore:
        """Create NVC RTL acceleration core configuration."""

        # Generate RTL for NVC acceleration mesh
        rtl_content = f'''
// NVC RTL Simulation Acceleration Core
// Auto-generated for {core_count} parallel acceleration units

module nvc_accel_core (
    input wire clk,
    input wire rst,

    // AXI-Lite slave interface
    input wire [31:0] s_axi_awaddr,
    input wire [2:0]  s_axi_awprot,
    input wire        s_axi_awvalid,
    output wire       s_axi_awready,

    input wire [31:0] s_axi_wdata,
    input wire [3:0]  s_axi_wstrb,
    input wire        s_axi_wvalid,
    output wire       s_axi_wready,

    output wire [1:0] s_axi_bresp,
    output wire       s_axi_bvalid,
    input wire        s_axi_bready,

    input wire [31:0] s_axi_araddr,
    input wire [2:0]  s_axi_arprot,
    input wire        s_axi_arvalid,
    output wire       s_axi_arready,

    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input wire         s_axi_rready,

    // Acceleration control
    output wire        accel_busy,
    output wire [31:0] perf_counter
);

// Parameters
localparam NUM_CORES = {core_count};
localparam CORE_ADDR_BITS = $clog2(NUM_CORES);

// Internal signals
reg [31:0] core_control [0:NUM_CORES-1];
reg [31:0] core_status [0:NUM_CORES-1];
reg [31:0] core_pc [0:NUM_CORES-1];
reg [31:0] performance_counter;

// Core memory (4KB per core)
reg [31:0] core_memory [0:NUM_CORES-1][0:1023];

// Synthesis acceleration state
reg [31:0] synth_state [0:NUM_CORES-1];
reg [31:0] logic_3d_strength [0:NUM_CORES-1];
reg [31:0] logic_3d_certainty [0:NUM_CORES-1];
reg [7:0]  logic_3d_value [0:NUM_CORES-1];

// AXI registers
reg [31:0] axi_awaddr;
reg [31:0] axi_wdata;
reg [3:0]  axi_wstrb;
reg        axi_awready;
reg        axi_wready;
reg [1:0]  axi_bresp;
reg        axi_bvalid;
reg [31:0] axi_araddr;
reg        axi_arready;
reg [31:0] axi_rdata;
reg [1:0]  axi_rresp;
reg        axi_rvalid;

// Address decoding
wire [CORE_ADDR_BITS-1:0] core_id;
wire [9:0] core_offset;
assign core_id = axi_araddr[CORE_ADDR_BITS+11:12];
assign core_offset = axi_araddr[11:2];

// AXI write interface
assign s_axi_awready = axi_awready;
assign s_axi_wready = axi_wready;
assign s_axi_bresp = axi_bresp;
assign s_axi_bvalid = axi_bvalid;

always @(posedge clk) begin
    if (rst) begin
        axi_awready <= 1'b1;
        axi_wready <= 1'b1;
        axi_bresp <= 2'b0;
        axi_bvalid <= 1'b0;
    end else begin
        if (s_axi_awvalid && s_axi_wvalid && axi_awready && axi_wready) begin
            axi_awaddr <= s_axi_awaddr;
            axi_wdata <= s_axi_wdata;
            axi_wstrb <= s_axi_wstrb;
            axi_bvalid <= 1'b1;
            axi_awready <= 1'b0;
            axi_wready <= 1'b0;

            // Write to core memory
            if (s_axi_awaddr[31:12] < NUM_CORES) begin
                core_memory[s_axi_awaddr[CORE_ADDR_BITS+11:12]][s_axi_awaddr[11:2]] <= s_axi_wdata;
            end
        end

        if (axi_bvalid && s_axi_bready) begin
            axi_bvalid <= 1'b0;
            axi_awready <= 1'b1;
            axi_wready <= 1'b1;
        end
    end
end

// AXI read interface
assign s_axi_arready = axi_arready;
assign s_axi_rdata = axi_rdata;
assign s_axi_rresp = axi_rresp;
assign s_axi_rvalid = axi_rvalid;

always @(posedge clk) begin
    if (rst) begin
        axi_arready <= 1'b1;
        axi_rvalid <= 1'b0;
        axi_rresp <= 2'b0;
        axi_rdata <= 32'h0;
    end else begin
        if (s_axi_arvalid && axi_arready) begin
            axi_araddr <= s_axi_araddr;
            axi_rvalid <= 1'b1;
            axi_arready <= 1'b0;

            // Read from core memory or status
            if (s_axi_araddr[31:12] < NUM_CORES) begin
                case (s_axi_araddr[11:10])
                    2'b00: axi_rdata <= core_memory[core_id][core_offset]; // Core memory
                    2'b01: axi_rdata <= core_status[core_id];               // Status
                    2'b10: axi_rdata <= synth_state[core_id];              // Synthesis state
                    2'b11: axi_rdata <= performance_counter;                // Performance
                endcase
            end else begin
                axi_rdata <= 32'hDEADBEEF; // Invalid address
            end
        end

        if (axi_rvalid && s_axi_rready) begin
            axi_rvalid <= 1'b0;
            axi_arready <= 1'b1;
        end
    end
end

// Acceleration cores
integer i;
always @(posedge clk) begin
    if (rst) begin
        performance_counter <= 0;
        for (i = 0; i < NUM_CORES; i = i + 1) begin
            core_control[i] <= 0;
            core_status[i] <= 0;
            core_pc[i] <= 0;
            synth_state[i] <= 0;
            logic_3d_strength[i] <= 32'h3F800000;  // 1.0 in IEEE 754
            logic_3d_certainty[i] <= 32'h3F800000; // 1.0 in IEEE 754
            logic_3d_value[i] <= 8'h0;
        end
    end else begin
        performance_counter <= performance_counter + 1;

        // Core execution simulation
        for (i = 0; i < NUM_CORES; i = i + 1) begin
            if (core_control[i][0]) begin // Enable bit
                core_pc[i] <= core_pc[i] + 1;
                synth_state[i] <= synth_state[i] + 2; // Synthesis acceleration

                // 3D logic processing
                if (synth_state[i][7:0] == 8'hFF) begin
                    logic_3d_value[i] <= ~logic_3d_value[i];
                    // Simulate strength decay for realistic 3D logic
                    if (logic_3d_strength[i] > 32'h3F000000) // 0.5 in IEEE 754
                        logic_3d_strength[i] <= logic_3d_strength[i] - 1;
                end

                core_status[i] <= {{24'h0}}, {{4'h1}}, {{4'h0}}; // Running status
            end else begin
                core_status[i] <= 32'h0; // Idle
            end
        end
    end
end

// Output assignments
assign accel_busy = |core_control; // Any core active
assign perf_counter = performance_counter;

endmodule
'''

        # Write RTL file
        rtl_path = f"{self.work_dir}/rtl/nvc_accel_core.v"
        with open(rtl_path, 'w') as f:
            f.write(rtl_content)

        return AccelCore(
            name=f"nvc_accel_{core_count}",
            rtl_files=[rtl_path],
            top_module="nvc_accel_core",
            parameters={"NUM_CORES": str(core_count)},
            memory_size_kb=core_count * 4,  # 4KB per core
            interfaces=["s_axi"]
        )

    def create_constraints(self, target: FPGATarget, core: AccelCore) -> str:
        """Create timing constraints for target FPGA."""

        constraints_content = f'''
# Timing constraints for {target.name} with {core.name}
# Auto-generated by FPGA build system

# Primary clock constraint
create_clock -period {target.clock_period_ns} -name clk [get_ports clk]

# Input delays (relative to clock)
set_input_delay -clock clk -max 2.000 [get_ports rst]
set_input_delay -clock clk -max 2.000 [get_ports s_axi_*]

# Output delays
set_output_delay -clock clk -max 2.000 [get_ports s_axi_*]
set_output_delay -clock clk -max 2.000 [get_ports accel_busy]
set_output_delay -clock clk -max 2.000 [get_ports perf_counter]

# Clock domain constraints
set_clock_groups -asynchronous -group [get_clocks clk]

# Area constraints to help with placement
set_property LOC SLICE_X0Y0 [get_cells -hierarchical -filter {{NAME =~ "*core_memory*"}}]

# High-performance implementation directives
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# For ZCU104 specific constraints
'''

        if target.name == 'ZCU104':
            constraints_content += '''
# ZCU104 specific pin assignments (if not using block design)
# These would be overridden by block design connections

# High-speed differential clock if needed
# set_property -dict {PACKAGE_PIN H9 IOSTANDARD LVDS} [get_ports clk_p]
# set_property -dict {PACKAGE_PIN G9 IOSTANDARD LVDS} [get_ports clk_n]

# Reset button
# set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS18} [get_ports rst]
'''

        constraints_path = f"{self.work_dir}/constraints/{target.name.lower()}_{core.name}.xdc"
        with open(constraints_path, 'w') as f:
            f.write(constraints_content)

        return constraints_path

    def create_build_tcl(self, target: FPGATarget, core: AccelCore, constraints_path: str) -> str:
        """Create comprehensive Vivado build script."""

        tcl_content = f'''
# Vivado build script for {target.name} with {core.name}
# Auto-generated by FPGA build system

# Set up project
set project_name "{target.name.lower()}_{core.name}"
set project_dir "{self.work_dir}/vivado_project"
set results_dir "{self.work_dir}/results"

# Create project directory
file mkdir $project_dir
file mkdir $results_dir

# Create project
create_project $project_name $project_dir -part {target.part} -force

# Set board part if available
'''

        if target.board_part:
            tcl_content += f'set_property board_part {target.board_part} [current_project]\n'

        tcl_content += f'''

# Add source files
add_files -norecurse {" ".join(core.rtl_files)}

# Add constraints
add_files -fileset constrs_1 -norecurse {constraints_path}

# Set top module
set_property top {core.top_module} [current_fileset]

# Update compile order
update_compile_order -fileset sources_1

puts "✓ Project setup complete"

# Run synthesis
puts "Starting synthesis..."
launch_runs synth_1 -jobs 8
wait_on_run synth_1

if {{[get_property PROGRESS [get_runs synth_1]] != "100%"}} {{
    puts "✗ Synthesis failed"
    exit 1
}}

puts "✓ Synthesis completed successfully"

# Open synthesized design for analysis
open_run synth_1 -name synth_1
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -input_pins -routable_nets -name timing_1
report_utilization -name utilization_1

# Save synthesis checkpoint
write_checkpoint -force $results_dir/${{project_name}}_synth.dcp

puts "✓ Synthesis analysis complete"

# Run implementation
puts "Starting implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {{[get_property PROGRESS [get_runs impl_1]] != "100%"}} {{
    puts "✗ Implementation failed"
    exit 1
}}

puts "✓ Implementation completed successfully"

# Open implemented design for final analysis
open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -input_pins -routable_nets -name timing_impl
report_utilization -hierarchical -name utilization_impl
report_power -name power_impl

# Check timing
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]

puts "Timing Results:"
puts "  Worst Negative Slack (Setup): $wns"
puts "  Worst Hold Slack: $whs"

if {{$wns >= 0}} {{
    puts "✓ Setup timing constraints MET"
}} else {{
    puts "⚠ Setup timing constraints VIOLATED by $wns"
}}

if {{$whs >= 0}} {{
    puts "✓ Hold timing constraints MET"
}} else {{
    puts "⚠ Hold timing constraints VIOLATED by $whs"
}}

# Save implementation results
write_checkpoint -force $results_dir/${{project_name}}_impl.dcp

# Copy bitstream to results
file copy -force $project_dir/$project_name.runs/impl_1/{core.top_module}.bit $results_dir/${{project_name}}.bit

puts "✓ Bitstream generated: $results_dir/${{project_name}}.bit"

# Generate hardware handoff files for debugging
write_hw_platform -fixed -include_bit -force -file $results_dir/${{project_name}}.xsa

puts "✓ Build completed successfully"

# Summary
puts ""
puts "Build Summary:"
puts "============="
puts "Target: {target.name} ({target.part})"
puts "Core: {core.name}"
puts "Top Module: {core.top_module}"
puts "Bitstream: $results_dir/${{project_name}}.bit"
puts "Hardware Platform: $results_dir/${{project_name}}.xsa"
puts ""

exit 0
'''

        tcl_path = f"{self.work_dir}/tcl/build_{target.name.lower()}_{core.name}.tcl"
        with open(tcl_path, 'w') as f:
            f.write(tcl_content)

        return tcl_path

    def build_accelerator(self, target_name: str, core_count: int = 25) -> Dict:
        """Build complete acceleration system for target FPGA."""

        if target_name not in self.FPGA_TARGETS:
            raise ValueError(f"Unknown FPGA target: {target_name}")

        target = self.FPGA_TARGETS[target_name]

        print(f"Building NVC acceleration for {target.name}")
        print("=" * 50)

        # Create acceleration core
        print(f"Generating {core_count}-core acceleration RTL...")
        core = self.create_nvc_accel_core(core_count)
        print(f"✓ Generated {core.name}")

        # Create constraints
        print("Creating timing constraints...")
        constraints_path = self.create_constraints(target, core)
        print(f"✓ Constraints: {constraints_path}")

        # Create build script
        print("Creating Vivado build script...")
        build_script = self.create_build_tcl(target, core, constraints_path)
        print(f"✓ Build script: {build_script}")

        # Run Vivado build
        print("Running Vivado synthesis and implementation...")
        try:
            result = subprocess.run([
                self.vivado_path, '-mode', 'batch', '-source', build_script
            ], capture_output=True, text=True, timeout=3600)  # 1 hour timeout

            if result.returncode == 0:
                print("✓ Build completed successfully!")

                # Extract results
                bitstream_path = f"{self.work_dir}/results/{target.name.lower()}_{core.name}.bit"
                xsa_path = f"{self.work_dir}/results/{target.name.lower()}_{core.name}.xsa"

                build_results = {
                    'success': True,
                    'target': target.name,
                    'core_count': core_count,
                    'bitstream_path': bitstream_path if os.path.exists(bitstream_path) else None,
                    'xsa_path': xsa_path if os.path.exists(xsa_path) else None,
                    'build_log': result.stdout
                }

                # Extract timing results
                if "Worst Negative Slack (Setup):" in result.stdout:
                    for line in result.stdout.split('\n'):
                        if "Worst Negative Slack (Setup):" in line:
                            try:
                                wns = float(line.split(':')[1].strip())
                                build_results['setup_slack'] = wns
                                build_results['timing_met'] = wns >= 0
                            except:
                                pass

                return build_results

            else:
                print(f"✗ Build failed: {result.stderr}")
                return {
                    'success': False,
                    'error': result.stderr,
                    'build_log': result.stdout
                }

        except subprocess.TimeoutExpired:
            print("✗ Build timed out")
            return {'success': False, 'error': 'Build timed out after 1 hour'}
        except Exception as e:
            print(f"✗ Build error: {e}")
            return {'success': False, 'error': str(e)}

    def program_fpga(self, target_name: str, bitstream_path: str) -> bool:
        """Program target FPGA with bitstream."""

        if not os.path.exists(bitstream_path):
            print(f"✗ Bitstream not found: {bitstream_path}")
            return False

        print(f"Programming {target_name} with {bitstream_path}")

        # Create programming script
        prog_script_content = f'''
# Program {target_name} FPGA
open_hw_manager
connect_hw_server -allow_non_jtag

# Connect to target
open_hw_target

# Get device (adapt for different FPGAs)
set device [lindex [get_hw_devices] 0]
puts "Programming device: $device"

# Configure programming files
set_property PROGRAM.FILE {{{bitstream_path}}} $device
set_property PROBES.FILE {{}} $device
set_property FULL_PROBES.FILE {{}} $device

# Program device
program_hw_devices $device
refresh_hw_device $device

puts "✓ Programming completed successfully"
close_hw_manager
exit 0
'''

        prog_script_path = f"{self.work_dir}/tcl/program_{target_name.lower()}.tcl"
        with open(prog_script_path, 'w') as f:
            f.write(prog_script_content)

        try:
            result = subprocess.run([
                self.vivado_path, '-mode', 'batch', '-source', prog_script_path
            ], capture_output=True, text=True, timeout=300)

            if result.returncode == 0 and "Programming completed" in result.stdout:
                print("✓ FPGA programming successful")
                return True
            else:
                print(f"✗ Programming failed: {result.stderr}")
                return False

        except Exception as e:
            print(f"✗ Programming error: {e}")
            return False

def main():
    """Test the FPGA build system."""

    print("FPGA Build System Test")
    print("=" * 30)

    builder = FPGABuildSystem()

    # Test building for ZCU104
    print("Building acceleration for ZCU104...")
    result = builder.build_accelerator('zcu104', core_count=25)

    if result['success']:
        print("\n✅ BUILD SUCCESS!")
        print(f"Bitstream: {result['bitstream_path']}")
        if 'timing_met' in result:
            print(f"Timing: {'✓ MET' if result['timing_met'] else '✗ VIOLATED'}")

        # Program FPGA if bitstream exists
        if result['bitstream_path'] and os.path.exists(result['bitstream_path']):
            print("\nProgramming ZCU104...")
            prog_success = builder.program_fpga('zcu104', result['bitstream_path'])
            if prog_success:
                print("🚀 Ready for hardware acceleration testing!")
            else:
                print("⚠ Programming failed - check JTAG connection")
    else:
        print("\n❌ BUILD FAILED")
        print(f"Error: {result.get('error', 'Unknown error')}")

if __name__ == "__main__":
    main()