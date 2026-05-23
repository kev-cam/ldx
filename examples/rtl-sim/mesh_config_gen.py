#!/usr/bin/env python3
"""
mesh_config_gen.py — Generate parameterizable RTL simulation mesh configurations.

Creates different mesh sizes (N×N cores) and generates appropriate netlists
to find optimal core counts for different design types.
"""

import argparse
import math
import os
import subprocess
import json
from pathlib import Path

def generate_mesh_config(mesh_size):
    """Generate configuration for N×N mesh."""
    num_cores = mesh_size * mesh_size

    config = {
        "mesh_width": mesh_size,
        "mesh_height": mesh_size,
        "num_cores": num_cores,
        "memory_per_core_kb": 4,
        "total_memory_kb": num_cores * 4,
        "max_gates_per_core": 256,
        "max_total_gates": num_cores * 256,
        "mesh_topology": "2d_grid",
        "sync_protocol": "barrier"
    }

    return config

def estimate_performance(design_size, mesh_config):
    """Estimate performance for given design size and mesh configuration."""
    num_gates = design_size
    num_cores = mesh_config["num_cores"]

    if num_gates <= num_cores:
        # More cores than gates - limited parallelism
        effective_cores = num_gates
        gates_per_core = 1
        load_imbalance = num_cores / num_gates if num_gates > 0 else float('inf')
    else:
        # More gates than cores - good parallelism
        effective_cores = num_cores
        gates_per_core = math.ceil(num_gates / num_cores)
        load_imbalance = 1.0 + (num_gates % num_cores) / num_cores

    # Estimate cross-partition communication (simplified model)
    # Assumes ~20% of signals cross partitions for typical designs
    cross_partition_ratio = 0.2 if num_cores > 1 else 0.0
    cross_edges = int(num_gates * cross_partition_ratio)

    # Performance model
    eval_cycles_per_gate = 2
    comm_cycles_per_signal = 5
    sync_cycles = 20

    # Parallel execution time
    parallel_eval = gates_per_core * eval_cycles_per_gate
    parallel_comm = cross_edges * comm_cycles_per_signal / effective_cores
    parallel_sync = sync_cycles

    total_parallel_cycles = parallel_eval + parallel_comm + parallel_sync

    # Sequential baseline
    sequential_cycles = num_gates * eval_cycles_per_gate

    # Speedup calculation
    speedup = sequential_cycles / total_parallel_cycles if total_parallel_cycles > 0 else 0
    efficiency = speedup / effective_cores if effective_cores > 0 else 0

    return {
        "gates_per_core": gates_per_core,
        "effective_cores": effective_cores,
        "load_imbalance": load_imbalance,
        "cross_edges": cross_edges,
        "estimated_speedup": speedup,
        "parallel_efficiency": efficiency,
        "total_cycles": total_parallel_cycles
    }

def generate_test_designs():
    """Generate test designs of various sizes and types."""
    designs = []

    # Small designs (good for small meshes)
    designs.append({
        "name": "4bit_adder",
        "type": "arithmetic",
        "gates": 20,
        "description": "4-bit ripple-carry adder"
    })

    designs.append({
        "name": "8bit_counter",
        "type": "sequential",
        "gates": 32,
        "description": "8-bit binary counter"
    })

    # Medium designs (good for medium meshes)
    designs.append({
        "name": "16bit_alu",
        "type": "arithmetic",
        "gates": 80,
        "description": "16-bit ALU"
    })

    designs.append({
        "name": "32bit_adder",
        "type": "arithmetic",
        "gates": 160,
        "description": "32-bit ripple-carry adder"
    })

    designs.append({
        "name": "simple_cpu",
        "type": "processor",
        "gates": 256,
        "description": "Simple 3-stage CPU"
    })

    # Large designs (good for large meshes)
    designs.append({
        "name": "risc_cpu",
        "type": "processor",
        "gates": 500,
        "description": "5-stage RISC CPU pipeline"
    })

    designs.append({
        "name": "crypto_unit",
        "type": "specialized",
        "gates": 800,
        "description": "AES encryption unit"
    })

    designs.append({
        "name": "gpu_core",
        "type": "parallel",
        "gates": 1200,
        "description": "Simple GPU compute core"
    })

    # Very large designs (stress test)
    designs.append({
        "name": "soc_subsystem",
        "type": "system",
        "gates": 2000,
        "description": "SoC subsystem with caches"
    })

    designs.append({
        "name": "fpga_fabric",
        "type": "reconfigurable",
        "gates": 4000,
        "description": "Small FPGA fabric model"
    })

    return designs

def run_performance_sweep():
    """Run performance sweep across different mesh sizes and designs."""
    mesh_sizes = [2, 3, 4, 5, 6, 7, 8, 10, 12]
    designs = generate_test_designs()

    results = []

    print("RTL Simulation Performance Sweep")
    print("="*50)
    print(f"{'Design':<15} {'Gates':<6} {'Mesh':<6} {'Cores':<6} {'Speedup':<8} {'Efficiency':<10} {'Best':<4}")
    print("-"*50)

    for design in designs:
        best_speedup = 0
        best_config = None
        design_results = []

        for mesh_size in mesh_sizes:
            config = generate_mesh_config(mesh_size)
            perf = estimate_performance(design["gates"], config)

            result = {
                "design": design["name"],
                "design_gates": design["gates"],
                "design_type": design["type"],
                "mesh_size": mesh_size,
                "num_cores": config["num_cores"],
                "config": config,
                "performance": perf
            }

            design_results.append(result)

            if perf["estimated_speedup"] > best_speedup:
                best_speedup = perf["estimated_speedup"]
                best_config = result

        # Print best configuration for this design
        best = best_config
        print(f"{design['name']:<15} {design['gates']:<6} "
              f"{best['mesh_size']}×{best['mesh_size']:<4} {best['num_cores']:<6} "
              f"{best_speedup:<8.1f} {best['performance']['parallel_efficiency']:<10.1f} {'*':<4}")

        results.extend(design_results)

    return results

def generate_optimal_configs(results):
    """Generate optimal mesh configurations for different design classes."""
    design_types = {}

    # Group results by design type
    for result in results:
        dtype = result["design_type"]
        if dtype not in design_types:
            design_types[dtype] = []
        design_types[dtype].append(result)

    print("\nOptimal Configurations by Design Type:")
    print("="*50)

    recommendations = {}

    for dtype, type_results in design_types.items():
        # Find best average performance across designs of this type
        mesh_perf = {}

        for result in type_results:
            mesh_size = result["mesh_size"]
            if mesh_size not in mesh_perf:
                mesh_perf[mesh_size] = []
            mesh_perf[mesh_size].append(result["performance"]["estimated_speedup"])

        # Calculate average speedup for each mesh size
        mesh_avg = {}
        for mesh_size, speedups in mesh_perf.items():
            mesh_avg[mesh_size] = sum(speedups) / len(speedups)

        # Find best mesh size for this design type
        best_mesh = max(mesh_avg, key=mesh_avg.get)
        best_speedup = mesh_avg[best_mesh]

        print(f"{dtype.capitalize():<15}: {best_mesh}×{best_mesh} mesh "
              f"({best_mesh**2} cores), avg {best_speedup:.1f}× speedup")

        recommendations[dtype] = {
            "optimal_mesh_size": best_mesh,
            "num_cores": best_mesh ** 2,
            "avg_speedup": best_speedup,
            "config": generate_mesh_config(best_mesh)
        }

    return recommendations

def main():
    parser = argparse.ArgumentParser(description="Generate RTL simulation mesh configurations")
    parser.add_argument("--sweep", action="store_true", help="Run performance sweep")
    parser.add_argument("--mesh-size", type=int, default=5, help="Generate config for specific mesh size")
    parser.add_argument("--output", type=str, help="Output file for results")

    args = parser.parse_args()

    if args.sweep:
        print("Running performance sweep across mesh sizes and designs...")
        results = run_performance_sweep()
        recommendations = generate_optimal_configs(results)

        if args.output:
            output_data = {
                "results": results,
                "recommendations": recommendations,
                "summary": "RTL simulation mesh configuration performance sweep"
            }
            with open(args.output, 'w') as f:
                json.dump(output_data, f, indent=2)
            print(f"\nDetailed results written to {args.output}")
    else:
        config = generate_mesh_config(args.mesh_size)
        print(f"Configuration for {args.mesh_size}×{args.mesh_size} mesh:")
        print(json.dumps(config, indent=2))

if __name__ == "__main__":
    main()