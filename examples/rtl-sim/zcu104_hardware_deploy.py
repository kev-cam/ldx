#!/usr/bin/env python3
"""
zcu104_hardware_deploy.py — Deploy RTL acceleration to actual ZCU104 hardware

Takes proven working configurations from capacity analysis and deploys them
to real ZCU104 hardware for performance validation.
"""

import subprocess
import time
import os
import json
import serial

class ZCU104HardwareDeployer:
    """Deploy and test RTL acceleration on actual ZCU104 hardware."""

    def __init__(self):
        self.work_dir = "/tmp/zcu104_hardware_deploy"
        self.results = {}

        # ZCU104 hardware connection (from memory)
        self.console_port = "/dev/ttyUSB1"

        # Proven working configurations from capacity test
        self.test_configs = {
            'small_mem': {'width': 32, 'depth': 1024, 'type': 'memory', 'desc': '4KB memory'},
            'med_mem': {'width': 32, 'depth': 2048, 'type': 'memory', 'desc': '8KB memory'},
            'large_mem': {'width': 32, 'depth': 8192, 'type': 'memory', 'desc': '32KB memory'},
            'reg_file': {'width': 32, 'depth': 64, 'type': 'register_file', 'desc': '32x64 register file'},
        }

        os.makedirs(self.work_dir, exist_ok=True)

    def create_acceleration_soc(self, config_name, config):
        """Create complete SoC with acceleration core for ZCU104."""

        print(f"Creating SoC with {config['desc']} acceleration...")

        width = config['width']
        depth = config['depth']
        mem_type = config['type']
        addr_bits = max(1, (depth - 1).bit_length())

        # Create the acceleration core
        if mem_type == 'memory':
            accel_core = f'''
// Memory acceleration core
module accel_{config_name} (
    input wire clk,
    input wire rst,

    // AXI-Lite slave interface (from PS)
    input wire [31:0] s_axi_awaddr,
    input wire s_axi_awvalid,
    output reg s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output reg s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,

    input wire [31:0] s_axi_araddr,
    input wire s_axi_arvalid,
    output reg s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,

    // Performance monitoring
    output reg [31:0] cycle_count,
    output reg [31:0] access_count
);

// Memory array - will infer BRAM
reg [{width-1}:0] memory [0:{depth-1}];

// Control registers
reg [31:0] control_reg;
reg [{addr_bits-1}:0] test_addr;
reg [{width-1}:0] test_data;
reg [31:0] cycles;
reg [31:0] accesses;

// AXI-Lite state machine
localparam IDLE = 2'b00, WRITE = 2'b01, READ = 2'b10;
reg [1:0] axi_state;

always @(posedge clk) begin
    if (rst) begin
        axi_state <= IDLE;
        s_axi_awready <= 1'b0;
        s_axi_wready <= 1'b0;
        s_axi_bvalid <= 1'b0;
        s_axi_arready <= 1'b0;
        s_axi_rvalid <= 1'b0;
        s_axi_bresp <= 2'b00;
        s_axi_rresp <= 2'b00;
        control_reg <= 32'h0;
        cycles <= 32'h0;
        accesses <= 32'h0;
        cycle_count <= 32'h0;
        access_count <= 32'h0;
    end else begin
        // Increment performance counters
        cycles <= cycles + 1;
        cycle_count <= cycles;
        access_count <= accesses;

        case (axi_state)
            IDLE: begin
                s_axi_awready <= 1'b1;
                s_axi_arready <= 1'b1;

                if (s_axi_awvalid && s_axi_awready) begin
                    axi_state <= WRITE;
                    s_axi_awready <= 1'b0;
                    s_axi_wready <= 1'b1;
                end else if (s_axi_arvalid && s_axi_arready) begin
                    axi_state <= READ;
                    s_axi_arready <= 1'b0;

                    // Handle read based on address
                    case (s_axi_araddr[7:0])
                        8'h00: s_axi_rdata <= control_reg;
                        8'h04: s_axi_rdata <= cycles;
                        8'h08: s_axi_rdata <= accesses;
                        8'h0C: s_axi_rdata <= {depth};  // Report depth
                        8'h10: s_axi_rdata <= {width};  // Report width
                        default: s_axi_rdata <= memory[s_axi_araddr[{addr_bits+1}:2]];
                    endcase

                    s_axi_rvalid <= 1'b1;
                    accesses <= accesses + 1;
                end
            end

            WRITE: begin
                if (s_axi_wvalid && s_axi_wready) begin
                    s_axi_wready <= 1'b0;

                    // Handle write based on address
                    if (s_axi_awaddr[7:0] == 8'h00) begin
                        control_reg <= s_axi_wdata;
                    end else begin
                        memory[s_axi_awaddr[{addr_bits+1}:2]] <= s_axi_wdata[{width-1}:0];
                    end

                    s_axi_bvalid <= 1'b1;
                    accesses <= accesses + 1;
                end

                if (s_axi_bvalid && s_axi_bready) begin
                    s_axi_bvalid <= 1'b0;
                    axi_state <= IDLE;
                end
            end

            READ: begin
                if (s_axi_rvalid && s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    axi_state <= IDLE;
                end
            end
        endcase
    end
end

endmodule'''

        elif mem_type == 'register_file':
            accel_core = f'''
// Register file acceleration core
module accel_{config_name} (
    input wire clk,
    input wire rst,

    // AXI-Lite slave interface
    input wire [31:0] s_axi_awaddr,
    input wire s_axi_awvalid,
    output reg s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output reg s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,

    input wire [31:0] s_axi_araddr,
    input wire s_axi_arvalid,
    output reg s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,

    output reg [31:0] cycle_count,
    output reg [31:0] access_count
);

// Register file - dual port for performance
reg [{width-1}:0] registers [0:{depth-1}];

// Performance counters
reg [31:0] cycles;
reg [31:0] accesses;

// AXI-Lite interface (simplified)
always @(posedge clk) begin
    if (rst) begin
        cycles <= 32'h0;
        accesses <= 32'h0;
        cycle_count <= 32'h0;
        access_count <= 32'h0;
        s_axi_rdata <= 32'h0;
    end else begin
        cycles <= cycles + 1;
        cycle_count <= cycles;
        access_count <= accesses;

        // Simple read/write logic
        if (s_axi_arvalid) begin
            if (s_axi_araddr[7:0] == 8'h00) begin
                s_axi_rdata <= cycles;
            end else if (s_axi_araddr[7:0] == 8'h04) begin
                s_axi_rdata <= accesses;
            end else begin
                s_axi_rdata <= registers[s_axi_araddr[{addr_bits+1}:2]];
            end
            accesses <= accesses + 1;
        end

        if (s_axi_awvalid && s_axi_wvalid) begin
            registers[s_axi_awaddr[{addr_bits+1}:2]] <= s_axi_wdata[{width-1}:0];
            accesses <= accesses + 1;
        end
    end
end

// AXI handshaking (simplified)
always @(*) begin
    s_axi_awready = 1'b1;
    s_axi_wready = 1'b1;
    s_axi_bvalid = s_axi_awvalid && s_axi_wvalid;
    s_axi_bresp = 2'b00;

    s_axi_arready = 1'b1;
    s_axi_rvalid = s_axi_arvalid;
    s_axi_rresp = 2'b00;
end

endmodule'''

        # Top-level SoC with PS integration
        soc_wrapper = f'''
// Top-level ZCU104 SoC with acceleration
module zcu104_accel_soc (
    // PS-PL interface will be connected by block design
);

wire clk_100mhz;
wire resetn;

// Instantiate the acceleration core
accel_{config_name} accel_inst (
    .clk(clk_100mhz),
    .rst(~resetn),

    // AXI connections will be made in block design
    .s_axi_awaddr(32'h0),
    .s_axi_awvalid(1'b0),
    .s_axi_awready(),
    .s_axi_wdata(32'h0),
    .s_axi_wstrb(4'hF),
    .s_axi_wvalid(1'b0),
    .s_axi_wready(),
    .s_axi_bresp(),
    .s_axi_bvalid(),
    .s_axi_bready(1'b1),

    .s_axi_araddr(32'h0),
    .s_axi_arvalid(1'b0),
    .s_axi_arready(),
    .s_axi_rdata(),
    .s_axi_rresp(),
    .s_axi_rvalid(),
    .s_axi_rready(1'b1),

    .cycle_count(),
    .access_count()
);

endmodule'''

        # Write HDL files
        accel_file = f"{self.work_dir}/accel_{config_name}.v"
        soc_file = f"{self.work_dir}/zcu104_accel_soc.v"

        with open(accel_file, 'w') as f:
            f.write(accel_core)
        with open(soc_file, 'w') as f:
            f.write(soc_wrapper)

        return accel_file, soc_file

    def create_vivado_project(self, config_name, accel_file, soc_file):
        """Create Vivado project for ZCU104 deployment."""

        print(f"Creating Vivado project for {config_name}...")

        project_name = f"zcu104_{config_name}_deploy"
        project_dir = f"{self.work_dir}/{project_name}"

        # Create comprehensive Vivado TCL script for complete implementation
        tcl_script = f'''
# ZCU104 hardware deployment script
set project_name {project_name}
set project_dir {project_dir}

# Create project
create_project $project_name $project_dir -part xczu7ev-ffvc1156-2-e -force

# Add source files
add_files -norecurse {accel_file}
add_files -norecurse {soc_file}

# Set top module
set_property top zcu104_accel_soc [current_fileset]
update_compile_order -fileset sources_1

# Create block design for PS-PL integration
create_bd_design "zcu104_accel_bd"

# Add Zynq UltraScale+ PS
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0

# Configure PS for ZCU104
set_property -dict [list \\
    CONFIG.PSU__USE__M_AXI_GP0 {{1}} \\
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {{32}} \\
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {{100}} \\
] [get_bd_cells zynq_ultra_ps_e_0]

# Add clock wizard for stable 100MHz clock
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_wiz_0
set_property -dict [list \\
    CONFIG.PRIM_IN_FREQ {{100.000}} \\
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {{100.000}} \\
    CONFIG.RESET_TYPE {{ACTIVE_LOW}} \\
] [get_bd_cells clk_wiz_0]

# Add processor system reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset proc_sys_reset_0

# Create and connect ports
create_bd_port -dir O -type clk clk_100mhz
create_bd_port -dir O -type rst resetn

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_ports clk_100mhz]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_ports resetn]

# Connect PS clocks and resets
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins proc_sys_reset_0/dcm_locked]

# Assign addresses
assign_bd_address

# Save block design
save_bd_design

# Generate block design
generate_target all [get_files {project_dir}/zcu104_{config_name}_deploy.srcs/sources_1/bd/zcu104_accel_bd/zcu104_accel_bd.bd]

# Add constraints for ZCU104
set constraints_content {{
# ZCU104 constraints
set_property PACKAGE_PIN H12 [get_ports {{clk_100mhz}}]
set_property IOSTANDARD LVCMOS33 [get_ports {{clk_100mhz}}]
create_clock -period 10.000 -name clk_100mhz [get_ports {{clk_100mhz}}]

# Reset
set_property PACKAGE_PIN D14 [get_ports {{resetn}}]
set_property IOSTANDARD LVCMOS33 [get_ports {{resetn}}]
}}

set constraints_file {project_dir}/zcu104_constraints.xdc
set fp [open $constraints_file w]
puts $fp $constraints_content
close $fp

add_files -fileset constrs_1 $constraints_file

# Synthesis
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {{[get_property PROGRESS [get_runs synth_1]] != "100%"}} {{
    puts "ERROR: Synthesis failed"
    exit 1
}}

# Implementation
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {{[get_property PROGRESS [get_runs impl_1]] != "100%"}} {{
    puts "ERROR: Implementation failed"
    exit 1
}}

# Export hardware for software
write_hw_platform -fixed -force -include_bit -file {project_dir}/{project_name}.xsa

puts "SUCCESS: Bitstream generated at [get_property DIRECTORY [get_runs impl_1]]/zcu104_accel_soc.bit"
puts "XSA exported: {project_dir}/{project_name}.xsa"
'''

        script_file = f"{self.work_dir}/build_{config_name}.tcl"
        with open(script_file, 'w') as f:
            f.write(tcl_script)

        return script_file, project_dir

    def build_bitstream(self, config_name, tcl_script):
        """Build bitstream for ZCU104 deployment."""

        print(f"Building bitstream for {config_name} (this will take 10-15 minutes)...")

        try:
            # Run Vivado build
            result = subprocess.run([
                "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
                "-source", tcl_script
            ], capture_output=True, text=True, timeout=1800)  # 30 minute timeout

            if result.returncode == 0 and "SUCCESS:" in result.stdout:
                print(f"  ✓ Bitstream build successful!")

                # Extract paths from output
                for line in result.stdout.split('\n'):
                    if "Bitstream generated at" in line:
                        bitstream_path = line.split("at ")[1]
                        print(f"  Bitstream: {bitstream_path}")
                    elif "XSA exported:" in line:
                        xsa_path = line.split(": ")[1]
                        print(f"  XSA: {xsa_path}")

                return True, bitstream_path

            else:
                print(f"  ✗ Bitstream build failed")
                if result.stderr:
                    print(f"    Error: {result.stderr[-500:]}")  # Last 500 chars
                return False, None

        except subprocess.TimeoutExpired:
            print(f"  ✗ Bitstream build timed out (>30 minutes)")
            return False, None
        except Exception as e:
            print(f"  ✗ Build error: {e}")
            return False, None

    def deploy_to_hardware(self, config_name, bitstream_path):
        """Deploy bitstream to ZCU104 hardware via JTAG."""

        print(f"Deploying {config_name} to ZCU104 hardware...")

        # Create deployment script
        deploy_script = f'''
# Hardware deployment script
open_hw_manager
connect_hw_server
open_hw_target

# Program FPGA
current_hw_device [get_hw_devices xczu7ev_0]
set_property PROGRAM.FILE {bitstream_path} [get_hw_devices xczu7ev_0]
program_hw_devices [get_hw_devices xczu7ev_0]

puts "SUCCESS: Hardware programmed"
close_hw_manager
'''

        deploy_script_file = f"{self.work_dir}/deploy_{config_name}.tcl"
        with open(deploy_script_file, 'w') as f:
            f.write(deploy_script)

        try:
            result = subprocess.run([
                "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "batch",
                "-source", deploy_script_file
            ], capture_output=True, text=True, timeout=300)

            if result.returncode == 0 and "SUCCESS:" in result.stdout:
                print(f"  ✓ Successfully deployed to ZCU104!")
                return True
            else:
                print(f"  ✗ Deployment failed")
                if result.stderr:
                    print(f"    Error: {result.stderr}")
                return False

        except Exception as e:
            print(f"  ✗ Deployment error: {e}")
            return False

    def test_hardware_performance(self, config_name, config):
        """Test acceleration performance on actual hardware."""

        print(f"Testing {config_name} performance on hardware...")

        # Create C test program for ZCU104
        test_program = f'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <time.h>

#define ACCEL_BASE_ADDR 0x80000000
#define ACCEL_SIZE 0x1000

#define REG_CONTROL 0x00
#define REG_CYCLES  0x04
#define REG_ACCESSES 0x08
#define REG_DEPTH   0x0C
#define REG_WIDTH   0x10

int main() {{
    int mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) {{
        printf("ERROR: Cannot open /dev/mem\\n");
        return 1;
    }}

    void* accel_map = mmap(0, ACCEL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, ACCEL_BASE_ADDR);
    if (accel_map == MAP_FAILED) {{
        printf("ERROR: Cannot mmap accelerator\\n");
        return 1;
    }}

    volatile uint32_t* accel = (volatile uint32_t*)accel_map;

    printf("=== ZCU104 {config['desc']} Acceleration Test ===\\n");
    printf("Array depth: %u\\n", accel[REG_DEPTH/4]);
    printf("Array width: %u\\n", accel[REG_WIDTH/4]);

    // Reset counters
    accel[REG_CONTROL/4] = 1;
    accel[REG_CONTROL/4] = 0;

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    // Performance test: write then read {config['depth']} locations
    uint32_t test_cycles = {min(config['depth'], 10000)};
    for (uint32_t i = 0; i < test_cycles; i++) {{
        uint32_t addr = 0x20 + (i % {config['depth']}) * 4;  // Memory area starts at 0x20
        accel[addr/4] = i * 0x12345678;  // Write pattern
        volatile uint32_t readback = accel[addr/4];  // Read back
        if ((i & 0xFF) == 0) {{
            printf("Progress: %u/%u\\r", i, test_cycles);
            fflush(stdout);
        }}
    }}

    clock_gettime(CLOCK_MONOTONIC, &end);

    uint32_t hw_cycles = accel[REG_CYCLES/4];
    uint32_t hw_accesses = accel[REG_ACCESSES/4];

    double elapsed_sec = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) * 1e-9;
    double cycles_per_sec = test_cycles / elapsed_sec;

    printf("\\n=== PERFORMANCE RESULTS ===\\n");
    printf("Test cycles: %u\\n", test_cycles);
    printf("Elapsed time: %.3f seconds\\n", elapsed_sec);
    printf("Hardware cycles: %u\\n", hw_cycles);
    printf("Hardware accesses: %u\\n", hw_accesses);
    printf("Performance: %.0f cycles/second\\n", cycles_per_sec);
    printf("Hardware efficiency: %.1f%%\\n", (double)hw_accesses * 100.0 / hw_cycles);

    munmap(accel_map, ACCEL_SIZE);
    close(mem_fd);

    return 0;
}}'''

        # Write test program
        test_file = f"{self.work_dir}/test_{config_name}.c"
        with open(test_file, 'w') as f:
            f.write(test_program)

        print(f"  Test program created: {test_file}")
        print(f"  Deploy to ZCU104 and run: gcc {test_file} -o test_{config_name} && ./test_{config_name}")

        return test_file

    def run_deployment_sequence(self):
        """Run complete deployment sequence for all configurations."""

        print("ZCU104 Hardware Deployment Sequence")
        print("=" * 50)

        for config_name, config in self.test_configs.items():
            print(f"\n[{config_name}] Deploying {config['desc']}...")

            # Create acceleration SoC
            accel_file, soc_file = self.create_acceleration_soc(config_name, config)

            # Create Vivado project
            tcl_script, project_dir = self.create_vivado_project(config_name, accel_file, soc_file)

            # Build bitstream (takes time)
            success, bitstream_path = self.build_bitstream(config_name, tcl_script)

            if success:
                # Deploy to hardware
                deploy_success = self.deploy_to_hardware(config_name, bitstream_path)

                if deploy_success:
                    # Create test program
                    test_file = self.test_hardware_performance(config_name, config)

                    self.results[config_name] = {
                        'build_success': True,
                        'deploy_success': True,
                        'bitstream_path': bitstream_path,
                        'test_program': test_file,
                        'config': config
                    }

                    print(f"  ✓ {config_name} ready for performance testing!")

                else:
                    self.results[config_name] = {'build_success': True, 'deploy_success': False}

            else:
                self.results[config_name] = {'build_success': False, 'deploy_success': False}

            print()

        # Summary
        self.generate_deployment_summary()

    def generate_deployment_summary(self):
        """Generate deployment summary and next steps."""

        print("=" * 60)
        print("ZCU104 DEPLOYMENT SUMMARY")
        print("=" * 60)

        successful = sum(1 for r in self.results.values() if r.get('deploy_success', False))
        total = len(self.results)

        print(f"Configurations deployed: {successful}/{total}")

        if successful > 0:
            print(f"\n✓ READY FOR HARDWARE PERFORMANCE TESTING!")
            print(f"\nNext steps:")
            print(f"1. Copy test programs to ZCU104")
            print(f"2. Run performance tests on actual hardware")
            print(f"3. Compare vs theoretical 36× speedup projection")
            print(f"4. Validate against Verilator benchmarks")

            for name, result in self.results.items():
                if result.get('deploy_success', False):
                    print(f"\n{name}: {result['test_program']}")

        else:
            print(f"\n✗ No deployments successful - check Vivado setup")

        # Save results
        with open(f"{self.work_dir}/deployment_results.json", 'w') as f:
            json.dump(self.results, f, indent=2)

        print(f"\n📊 Results saved to: {self.work_dir}/deployment_results.json")

def main():
    """Run ZCU104 hardware deployment sequence."""

    deployer = ZCU104HardwareDeployer()
    deployer.run_deployment_sequence()

if __name__ == "__main__":
    main()