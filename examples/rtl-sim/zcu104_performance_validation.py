#!/usr/bin/env python3
"""
zcu104_performance_validation.py — Validate RTL accelerator performance on ZCU104

Test the deployed FPGA accelerator and measure real performance against projections.
"""

import subprocess
import time
import json
import sys

class ZCU104PerformanceValidator:
    """Validate ZCU104 RTL accelerator performance."""

    def __init__(self):
        self.results = {}
        self.console_port = "/dev/ttyUSB1"

    def test_fpga_connectivity(self):
        """Test if ZCU104 FPGA is programmed and responsive."""

        print("Testing ZCU104 FPGA connectivity...")

        # Try to read FPGA status via Vivado
        try:
            result = subprocess.run([
                "/opt/AMD/2025.2/Vivado/bin/vivado", "-mode", "tcl", "-source", "/dev/stdin"
            ], input="""
open_hw_manager
connect_hw_server
open_hw_target
current_hw_device [get_hw_devices xczu7_0]
puts "FPGA_STATUS: [get_property PROGRAM.DONE [get_hw_devices xczu7_0]]"
close_hw_manager
exit
""", capture_output=True, text=True, timeout=30)

            if "FPGA_STATUS: 1" in result.stdout:
                print("  ✓ FPGA programmed and ready")
                return True
            else:
                print("  ✗ FPGA not programmed or not responding")
                return False

        except Exception as e:
            print(f"  ✗ Connectivity test failed: {e}")
            return False

    def create_performance_benchmark(self):
        """Create software performance baseline for comparison."""

        print("Creating software performance baseline...")

        # Simulate the same 2048 memory operations in software
        import time

        start_time = time.time()

        # Equivalent to our FPGA test: 1024 writes + 1024 reads
        memory_array = [0] * 1024

        # Write phase
        for i in range(1024):
            memory_array[i] = i * 0x12345678

        # Read phase
        checksum = 0
        for i in range(1024):
            checksum ^= memory_array[i]

        end_time = time.time()
        total_operations = 2048
        elapsed_time = end_time - start_time
        software_ops_per_sec = total_operations / elapsed_time

        print(f"  Software baseline: {software_ops_per_sec:,.0f} operations/second")
        print(f"  Software time: {elapsed_time:.6f} seconds for 2048 operations")

        return software_ops_per_sec

    def estimate_fpga_performance(self):
        """Estimate FPGA performance based on design specs."""

        print("Estimating FPGA performance...")

        # Design specifications
        fpga_frequency_mhz = 125  # 125MHz clock
        operations_per_test = 2048  # Our test size
        cycles_per_operation = 1   # Single-cycle memory access (optimistic)

        # Calculate theoretical performance
        fpga_frequency_hz = fpga_frequency_mhz * 1_000_000
        cycles_per_test = operations_per_test * cycles_per_operation
        tests_per_second = fpga_frequency_hz / cycles_per_test
        operations_per_second = tests_per_second * operations_per_test

        print(f"  FPGA specs: {fpga_frequency_mhz}MHz, {operations_per_test} ops/test")
        print(f"  Theoretical: {operations_per_second:,.0f} operations/second")
        print(f"  Test duration: {cycles_per_test / fpga_frequency_hz * 1e6:.1f} microseconds")

        return operations_per_second

    def run_manual_fpga_test(self):
        """Guide user through manual FPGA test procedure."""

        print("\n" + "="*60)
        print("MANUAL FPGA PERFORMANCE TEST")
        print("="*60)

        print("\n🔧 FPGA Test Setup:")
        print("1. ZCU104 board should be powered and connected")
        print("2. FPGA is programmed with our accelerator bitstream ✓")
        print("3. Observe LEDs DS50-DS53 on the board")

        print("\n🧪 Test Procedure:")
        print("1. **Reset**: Flip SW19 switch to reset the accelerator")
        print("2. **Baseline**: All LEDs should be OFF initially")
        print("3. **Start Test**: Flip SW18 switch to trigger performance test")
        print("4. **Monitor**: Watch LED[0] (DS50) for test completion")
        print("5. **Result**: LED[0] lights up when 2048 operations complete")

        print(f"\n📊 Expected Performance:")
        print(f"  • Operations: 2048 (1024 writes + 1024 reads)")
        print(f"  • Target time: ~16 microseconds at 125MHz")
        print(f"  • Performance goal: >6M operations/second (beat Verilator)")

        # Interactive test
        print(f"\n⚡ Ready to test? Follow the steps above...")
        input("Press Enter when you have reset the FPGA (SW19)...")

        print("📍 Current LED status should be: ALL OFF")
        input("Press Enter when ready to start test (flip SW18)...")

        print("⏱️  Test running... Watch for LED[0] to light up...")
        start_time = time.time()

        input("Press Enter when LED[0] lights up (test complete)...")
        end_time = time.time()

        # Calculate measured performance
        test_duration = end_time - start_time
        operations = 2048
        measured_ops_per_sec = operations / test_duration

        print(f"\n🎯 MEASURED RESULTS:")
        print(f"  Test duration: {test_duration:.3f} seconds")
        print(f"  Measured performance: {measured_ops_per_sec:,.0f} operations/second")

        return test_duration, measured_ops_per_sec

    def analyze_performance_results(self, software_baseline, fpga_theoretical, fpga_measured):
        """Analyze and compare all performance results."""

        print(f"\n" + "="*60)
        print("PERFORMANCE ANALYSIS")
        print("="*60)

        # Comparison targets
        verilator_target = 6_000_000  # 6M cycles/sec
        nvc_baseline = 76_000        # 76K cycles/sec

        print(f"\n📊 PERFORMANCE COMPARISON:")
        print(f"{'Platform':<20} {'Ops/Second':<15} {'vs Verilator':<12} {'Status'}")
        print("-" * 65)
        print(f"{'NVC (baseline)':<20} {nvc_baseline:>14,} {nvc_baseline/verilator_target:>11.3f}× {'🔴 Slow'}")
        print(f"{'Software sim':<20} {software_baseline:>14,.0f} {software_baseline/verilator_target:>11.3f}× {'⚪ Reference'}")
        print(f"{'Verilator (target)':<20} {verilator_target:>14,} {'1.000×':>11} {'🎯 Target'}")
        print(f"{'FPGA (theory)':<20} {fpga_theoretical:>14,.0f} {fpga_theoretical/verilator_target:>11.1f}× {'💭 Projected'}")
        print(f"{'FPGA (measured)':<20} {fpga_measured:>14,.0f} {fpga_measured/verilator_target:>11.1f}× {'🏆 ACTUAL'}")

        # Victory analysis
        print(f"\n🏆 VICTORY ANALYSIS:")

        if fpga_measured > verilator_target:
            speedup = fpga_measured / verilator_target
            print(f"🎉 SUCCESS! FPGA beats Verilator by {speedup:.1f}×")
            print(f"👑 CROWN CLAIMED: Fastest open-source RTL simulator!")

            if fpga_measured > fpga_theoretical * 0.5:
                print(f"🎯 Performance meets expectations ({fpga_measured/fpga_theoretical:.1f}× of theoretical)")
            else:
                print(f"📉 Below theoretical, but still victorious!")

            victory_status = "VICTORY"

        elif fpga_measured > verilator_target * 0.8:
            ratio = fpga_measured / verilator_target
            print(f"🟡 CLOSE! {ratio:.1f}× vs Verilator - very competitive")
            print(f"🔧 Small optimizations could achieve victory")
            victory_status = "COMPETITIVE"

        else:
            gap = verilator_target / fpga_measured
            print(f"🔴 Verilator still faster by {gap:.1f}×")
            print(f"🔧 Need significant optimization to compete")
            victory_status = "NEEDS_WORK"

        # Economic analysis
        print(f"\n💰 COST ANALYSIS:")
        cost_per_performance = 7000 / fpga_measured  # $7K ZCU104 cost
        verilator_cost_per_performance = 2000 / verilator_target  # Estimate $2K workstation

        print(f"  FPGA cost/performance: ${cost_per_performance:.6f} per op/sec")
        print(f"  Verilator cost/performance: ${verilator_cost_per_performance:.6f} per op/sec")

        if fpga_measured > 0:
            cost_advantage = (verilator_cost_per_performance / cost_per_performance)
            print(f"  FPGA cost advantage: {cost_advantage:.1f}× better value")

        # Save results
        results = {
            'software_baseline_ops_per_sec': software_baseline,
            'fpga_theoretical_ops_per_sec': fpga_theoretical,
            'fpga_measured_ops_per_sec': fpga_measured,
            'verilator_target_ops_per_sec': verilator_target,
            'nvc_baseline_ops_per_sec': nvc_baseline,
            'victory_status': victory_status,
            'speedup_vs_verilator': fpga_measured / verilator_target,
            'cost_advantage': cost_advantage if fpga_measured > 0 else 0,
            'performance_efficiency': fpga_measured / fpga_theoretical if fpga_theoretical > 0 else 0
        }

        with open('/tmp/zcu104_performance_results.json', 'w') as f:
            json.dump(results, f, indent=2)

        print(f"\n📊 Results saved to: /tmp/zcu104_performance_results.json")

        return victory_status, results

    def run_complete_validation(self):
        """Run complete performance validation sequence."""

        print("ZCU104 RTL Accelerator Performance Validation")
        print("=" * 50)
        print("🎯 Goal: Validate 36× speedup and beat Verilator (6M ops/sec)")
        print()

        # Test connectivity
        if not self.test_fpga_connectivity():
            print("❌ FPGA not accessible - check programming")
            return False

        # Get performance baselines
        software_baseline = self.create_performance_benchmark()
        fpga_theoretical = self.estimate_fpga_performance()

        # Run manual FPGA test
        test_duration, fpga_measured = self.run_manual_fpga_test()

        # Analyze results
        victory_status, results = self.analyze_performance_results(
            software_baseline, fpga_theoretical, fpga_measured
        )

        # Final summary
        print(f"\n" + "="*60)
        print("FINAL VALIDATION SUMMARY")
        print("="*60)

        if victory_status == "VICTORY":
            print("🏆 MISSION ACCOMPLISHED!")
            print("👑 Fastest open-source RTL simulator achieved!")
            print(f"🚀 {results['speedup_vs_verilator']:.1f}× faster than Verilator")
        elif victory_status == "COMPETITIVE":
            print("📈 Strong performance - very close to victory!")
            print("🔧 Small optimizations needed for crown")
        else:
            print("📊 Good baseline established")
            print("🎯 Clear optimization targets identified")

        return victory_status == "VICTORY"

def main():
    """Run ZCU104 performance validation."""

    validator = ZCU104PerformanceValidator()
    success = validator.run_complete_validation()

    if success:
        print(f"\n🎊 RTL ACCELERATION PROJECT: SUCCESS!")
        print(f"Crown claimed: Fastest open-source RTL simulator! 👑")
    else:
        print(f"\n📈 Strong foundation built for future optimization")

    return success

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)