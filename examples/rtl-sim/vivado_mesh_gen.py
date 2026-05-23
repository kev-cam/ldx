#!/usr/bin/env python3
"""
vivado_mesh_gen.py — Generate Vivado projects for different mesh configurations.

Creates parameterizable RTL for N×N meshes and estimates FPGA resource utilization.
"""

import os
import json
import argparse
from pathlib import Path

def generate_mesh_rtl(mesh_size, output_dir):
    """Generate SystemVerilog RTL for N×N mesh."""

    num_cores = mesh_size * mesh_size

    # Generate mesh top-level module
    mesh_rtl = f'''// mesh_top_{mesh_size}x{mesh_size}.v — {mesh_size}×{mesh_size} RTL simulation mesh
// Generated automatically by vivado_mesh_gen.py

`timescale 1ns/1ps

module mesh_top_{mesh_size}x{mesh_size} #(
    parameter integer N = {mesh_size}
) (
    input  wire        clk,
    input  wire        reset,

    // Per-core reset and BRAM-load
    input  wire [N*N-1:0]      cpu_rst_req_vec,
    input  wire [N*N-1:0]      load_we_vec,
    input  wire [9:0]          load_addr,
    input  wire [31:0]         load_data,

    // Boundary ports — {mesh_size*4} total
    output wire [4*N-1:0]      bndry_tx_valid,
    input  wire [4*N-1:0]      bndry_tx_ready,
    output wire [4*N*32-1:0]   bndry_tx_data,
    input  wire [4*N-1:0]      bndry_rx_valid,
    output wire [4*N-1:0]      bndry_rx_ready,
    input  wire [4*N*32-1:0]   bndry_rx_data,

    // Performance monitoring
    output wire [N*N-1:0]      core_active,
    output wire [31:0]         total_gates_evaluated,
    output wire [31:0]         cross_partition_signals
);

    // Per-core port buses
    wire [3:0]   tx_valid [0:N-1][0:N-1];
    wire [3:0]   tx_ready [0:N-1][0:N-1];
    wire [127:0] tx_data  [0:N-1][0:N-1];
    wire [3:0]   rx_valid [0:N-1][0:N-1];
    wire [3:0]   rx_ready [0:N-1][0:N-1];
    wire [127:0] rx_data  [0:N-1][0:N-1];

    // Core instantiation
    genvar gx, gy;
    generate
        for (gx = 0; gx < N; gx = gx + 1) begin : gx_loop
            for (gy = 0; gy < N; gy = gy + 1) begin : gy_loop
                ldx_soc_mesh #(
                    .MY_X(gx+1),
                    .MY_Y(gy+1),
                    .HEX_FILE($sformatf("firmware_core_%0d_%0d.hex", gx, gy))
                ) core (
                    .clk(clk),
                    .reset(reset),
                    .load_we(load_we_vec[gx*N + gy]),
                    .load_addr(load_addr),
                    .load_data(load_data),
                    .cpu_rst_req(cpu_rst_req_vec[gx*N + gy]),
                    .tx_valid(tx_valid[gx][gy]),
                    .tx_ready(tx_ready[gx][gy]),
                    .tx_data (tx_data [gx][gy]),
                    .rx_valid(rx_valid[gx][gy]),
                    .rx_ready(rx_ready[gx][gy]),
                    .rx_data (rx_data [gx][gy])
                );

                // Performance monitoring
                assign core_active[gx*N + gy] = |tx_valid[gx][gy] | |rx_valid[gx][gy];
            end
        end
    endgenerate

    // Mesh interconnect (same pattern as original mesh_top.v)
    generate
        for (gx = 0; gx < N; gx = gx + 1) begin : x_wire
            for (gy = 0; gy < N; gy = gy + 1) begin : y_wire

                // East-West connections
                if (gx < N-1) begin : east_link
                    assign rx_valid[gx+1][gy][3]      = tx_valid[gx][gy][1];
                    assign rx_data [gx+1][gy][127:96] = tx_data [gx][gy][63:32];
                    assign tx_ready[gx][gy][1]        = rx_ready[gx+1][gy][3];

                    assign rx_valid[gx][gy][1]        = tx_valid[gx+1][gy][3];
                    assign rx_data [gx][gy][63:32]    = tx_data [gx+1][gy][127:96];
                    assign tx_ready[gx+1][gy][3]      = rx_ready[gx][gy][1];
                end else begin : east_bndry
                    assign bndry_tx_valid[N + gy]                = tx_valid[gx][gy][1];
                    assign bndry_tx_data [(N+gy)*32 +: 32]       = tx_data [gx][gy][63:32];
                    assign tx_ready[gx][gy][1]                   = bndry_tx_ready[N + gy];

                    assign rx_valid[gx][gy][1]                   = bndry_rx_valid[N + gy];
                    assign rx_data [gx][gy][63:32]               = bndry_rx_data[(N+gy)*32 +: 32];
                    assign bndry_rx_ready[N + gy]                = rx_ready[gx][gy][1];
                end

                if (gx == 0) begin : west_bndry
                    assign bndry_tx_valid[3*N + gy]              = tx_valid[gx][gy][3];
                    assign bndry_tx_data [(3*N+gy)*32 +: 32]     = tx_data [gx][gy][127:96];
                    assign tx_ready[gx][gy][3]                   = bndry_tx_ready[3*N + gy];

                    assign rx_valid[gx][gy][3]                   = bndry_rx_valid[3*N + gy];
                    assign rx_data [gx][gy][127:96]              = bndry_rx_data[(3*N+gy)*32 +: 32];
                    assign bndry_rx_ready[3*N + gy]              = rx_ready[gx][gy][3];
                end

                // North-South connections
                if (gy < N-1) begin : north_link
                    assign rx_valid[gx][gy+1][2]      = tx_valid[gx][gy][0];
                    assign rx_data [gx][gy+1][95:64]  = tx_data [gx][gy][31:0];
                    assign tx_ready[gx][gy][0]        = rx_ready[gx][gy+1][2];

                    assign rx_valid[gx][gy][0]        = tx_valid[gx][gy+1][2];
                    assign rx_data [gx][gy][31:0]     = tx_data [gx][gy+1][95:64];
                    assign tx_ready[gx][gy+1][2]      = rx_ready[gx][gy][0];
                end else begin : north_bndry
                    assign bndry_tx_valid[0*N + gx]              = tx_valid[gx][gy][0];
                    assign bndry_tx_data [(0*N+gx)*32 +: 32]     = tx_data [gx][gy][31:0];
                    assign tx_ready[gx][gy][0]                   = bndry_tx_ready[0*N + gx];

                    assign rx_valid[gx][gy][0]                   = bndry_rx_valid[0*N + gx];
                    assign rx_data [gx][gy][31:0]                = bndry_rx_data[(0*N+gx)*32 +: 32];
                    assign bndry_rx_ready[0*N + gx]              = rx_ready[gx][gy][0];
                end

                if (gy == 0) begin : south_bndry
                    assign bndry_tx_valid[2*N + gx]              = tx_valid[gx][gy][2];
                    assign bndry_tx_data [(2*N+gx)*32 +: 32]     = tx_data [gx][gy][95:64];
                    assign tx_ready[gx][gy][2]                   = bndry_tx_ready[2*N + gx];

                    assign rx_valid[gx][gy][2]                   = bndry_rx_valid[2*N + gx];
                    assign rx_data [gx][gy][95:64]               = bndry_rx_data[(2*N+gx)*32 +: 32];
                    assign bndry_rx_ready[2*N + gx]              = rx_ready[gx][gy][2];
                end
            end
        end
    endgenerate

    // Performance counters
    reg [31:0] gate_counter;
    reg [31:0] signal_counter;

    always @(posedge clk) begin
        if (reset) begin
            gate_counter <= 0;
            signal_counter <= 0;
        end else begin
            gate_counter <= gate_counter + $countones(core_active);
            signal_counter <= signal_counter + $countones(bndry_tx_valid);
        end
    end

    assign total_gates_evaluated = gate_counter;
    assign cross_partition_signals = signal_counter;

endmodule'''

    # Write RTL file
    rtl_path = Path(output_dir) / f"mesh_top_{mesh_size}x{mesh_size}.v"
    rtl_path.parent.mkdir(parents=True, exist_ok=True)

    with open(rtl_path, 'w') as f:
        f.write(mesh_rtl)

    return rtl_path

def estimate_fpga_resources(mesh_size):
    """Estimate FPGA resource utilization for N×N mesh."""

    num_cores = mesh_size * mesh_size

    # Resource estimates per core (based on our 25-core measurement)
    # 25 cores used: 16,666 LUTs, 22,114 FFs, 25.5 BRAMs, 3 DSPs
    luts_per_core = 16666 / 25      # ~667 LUTs per core
    ffs_per_core = 22114 / 25       # ~885 FFs per core
    brams_per_core = 25.5 / 25      # ~1.0 BRAM per core
    dsps_per_core = 3 / 25          # ~0.12 DSPs per core

    # Add interconnect overhead (scales with mesh edges)
    mesh_edges = mesh_size * (mesh_size - 1) * 2  # Bidirectional grid
    interconnect_luts = mesh_edges * 50            # ~50 LUTs per connection

    # Total estimates
    total_luts = num_cores * luts_per_core + interconnect_luts
    total_ffs = num_cores * ffs_per_core
    total_brams = num_cores * brams_per_core
    total_dsps = num_cores * dsps_per_core

    # ZCU104 (XCZU7EV) available resources
    max_luts = 230400
    max_ffs = 460800
    max_brams = 312
    max_dsps = 1728

    utilization = {
        "mesh_size": f"{mesh_size}×{mesh_size}",
        "num_cores": num_cores,
        "estimated_resources": {
            "luts": int(total_luts),
            "flip_flops": int(total_ffs),
            "bram_tiles": round(total_brams, 1),
            "dsp_slices": round(total_dsps, 1)
        },
        "utilization_percent": {
            "luts": round(100 * total_luts / max_luts, 1),
            "flip_flops": round(100 * total_ffs / max_ffs, 1),
            "bram_tiles": round(100 * total_brams / max_brams, 1),
            "dsp_slices": round(100 * total_dsps / max_dsps, 1)
        },
        "fits_zcu104": all([
            total_luts < max_luts * 0.9,      # 90% threshold
            total_ffs < max_ffs * 0.9,
            total_brams < max_brams * 0.9,
            total_dsps < max_dsps * 0.9
        ])
    }

    return utilization

def generate_test_configs():
    """Generate test configurations for different mesh sizes."""

    configs = []

    # Test different mesh sizes
    mesh_sizes = [2, 3, 4, 5, 6, 7, 8, 10, 12, 16]

    for size in mesh_sizes:
        config = {
            "mesh_size": size,
            "num_cores": size * size,
            "resource_estimate": estimate_fpga_resources(size),
            "target_designs": []
        }

        # Recommend suitable designs based on core count
        if size <= 3:
            config["target_designs"] = ["4bit_adder", "8bit_counter"]
        elif size <= 5:
            config["target_designs"] = ["16bit_alu", "32bit_adder"]
        elif size <= 8:
            config["target_designs"] = ["simple_cpu", "risc_cpu"]
        else:
            config["target_designs"] = ["crypto_unit", "gpu_core", "soc_subsystem"]

        configs.append(config)

    return configs

def main():
    parser = argparse.ArgumentParser(description="Generate Vivado mesh configurations")
    parser.add_argument("--mesh-size", type=int, help="Generate RTL for specific mesh size")
    parser.add_argument("--analyze", action="store_true", help="Analyze all configurations")
    parser.add_argument("--output-dir", default="generated_meshes", help="Output directory")

    args = parser.parse_args()

    if args.analyze:
        print("RTL Simulation Mesh Configuration Analysis")
        print("="*60)

        configs = generate_test_configs()

        print(f"{'Mesh':<8} {'Cores':<6} {'LUTs':<8} {'BRAMs':<8} {'Fits':<6} {'Recommended':<20}")
        print("-"*60)

        for config in configs:
            mesh_size = config["mesh_size"]
            resources = config["resource_estimate"]

            print(f"{mesh_size}×{mesh_size:<6} {config['num_cores']:<6} "
                  f"{resources['utilization_percent']['luts']:<7.1f}% "
                  f"{resources['utilization_percent']['bram_tiles']:<7.1f}% "
                  f"{'Yes' if resources['fits_zcu104'] else 'No':<6} "
                  f"{', '.join(config['target_designs'][:2]):<20}")

        # Save detailed analysis
        output_file = Path(args.output_dir) / "mesh_analysis.json"
        output_file.parent.mkdir(parents=True, exist_ok=True)

        with open(output_file, 'w') as f:
            json.dump(configs, f, indent=2)

        print(f"\\nDetailed analysis saved to {output_file}")

        # Find optimal configurations
        print("\\nOptimal Configurations:")
        print("-"*30)

        # Best small mesh (fits easily)
        small_meshes = [c for c in configs if c["resource_estimate"]["utilization_percent"]["luts"] < 20]
        if small_meshes:
            best_small = max(small_meshes, key=lambda x: x["num_cores"])
            print(f"Small designs:  {best_small['mesh_size']}×{best_small['mesh_size']} "
                  f"({best_small['num_cores']} cores, "
                  f"{best_small['resource_estimate']['utilization_percent']['luts']:.1f}% LUTs)")

        # Best large mesh (uses most of FPGA)
        large_meshes = [c for c in configs if c["resource_estimate"]["fits_zcu104"]]
        if large_meshes:
            best_large = max(large_meshes, key=lambda x: x["num_cores"])
            print(f"Large designs:  {best_large['mesh_size']}×{best_large['mesh_size']} "
                  f"({best_large['num_cores']} cores, "
                  f"{best_large['resource_estimate']['utilization_percent']['luts']:.1f}% LUTs)")

    elif args.mesh_size:
        print(f"Generating RTL for {args.mesh_size}×{args.mesh_size} mesh...")

        rtl_path = generate_mesh_rtl(args.mesh_size, args.output_dir)
        resources = estimate_fpga_resources(args.mesh_size)

        print(f"RTL generated: {rtl_path}")
        print(f"Estimated resource utilization:")
        print(f"  LUTs:  {resources['estimated_resources']['luts']} "
              f"({resources['utilization_percent']['luts']}%)")
        print(f"  BRAMs: {resources['estimated_resources']['bram_tiles']} "
              f"({resources['utilization_percent']['bram_tiles']}%)")
        print(f"  Fits ZCU104: {'Yes' if resources['fits_zcu104'] else 'No'}")

    else:
        print("Use --analyze to see all configurations or --mesh-size N to generate specific RTL")

if __name__ == "__main__":
    main()