# Parallel RTL Simulation Engine

Lock-stepped parallel RTL simulation using the ZCU104 25-core VexRiscv mesh with double-buffered memory.

## Architecture

- **25 cores**: 5×5 mesh, each simulates a netlist partition
- **Double-buffered memory**: Bank A/B alternating per cycle to avoid read/write conflicts  
- **Lock-stepped execution**: All cores evaluate synchronously, then propagate signals
- **No AXI round-trips**: Steady-state simulation runs entirely within FPGA

## Components

- `rtl_sim_engine.h/c` - Core simulation engine (runs on each VexRiscv)
- `rtl_sim_host.h/c` - Host controller (manages mesh via ZCU104 bridge)
- `rtl_sim_firmware.c` - Firmware that runs on each softcore
- `test_rtl_sim.c` - Test program demonstrating 32-bit adder simulation
- `gen_netlist.c` - Utility to generate test circuits

## Memory Layout (per core)

```
0x80000000-0x800007FF  Bank A (2KB state vectors)
0x80000800-0x80000FFF  Bank B (2KB state vectors) 
0x80001000-0x800017FF  Gate descriptors (2KB)
0x80001800-0x80001BFF  Remote signal descriptors (1KB)
0x80001C00-0x80001FFF  Partition metadata (1KB)
```

## Gate Types

- `GATE_AND` - Logical AND
- `GATE_OR` - Logical OR  
- `GATE_XOR` - Logical XOR
- `GATE_NOT` - Logical NOT
- `GATE_BUF` - Buffer
- `GATE_DFF` - D flip-flop (clocked)
- `GATE_REMOTE` - Cross-partition signal

## Simulation Protocol

1. **Load**: Distribute firmware and netlist partitions to all cores
2. **Initialize**: Set initial state vectors in both memory banks
3. **Simulate**: Lock-stepped evaluate→propagate→sync→swap cycles
4. **Collect**: Read final state from all cores

## Usage

```bash
# Build everything
make all

# Generate test circuit
make gen_netlist
./gen_netlist adder 32 > adder_32.netlist

# Run simulation (requires ZCU104)
sudo ./test_rtl_sim rtl_sim_firmware.bin

# Clean up
make clean
```

## Example: 32-bit Adder Test

The test program simulates a 32-bit ripple-carry adder:
- **Inputs**: A[31:0], B[31:0], carry_in
- **Outputs**: sum[31:0], carry_out  
- **Gates**: ~160 gates (5 per bit + interconnect)
- **Cycles**: ~40 cycles for full ripple propagation

Test cases validate against reference implementation:
- 0x00000000 + 0x00000000 + 0 = 0x00000000
- 0xFFFFFFFF + 0x00000001 + 0 = 0x00000000 (with carry)
- 0x12345678 + 0x87654321 + 0 = 0x99999999

## Performance Model

Each simulation cycle:
1. **Evaluate**: ~10 cycles per gate (depends on complexity)
2. **Propagate**: ~5 cycles per remote signal
3. **Sync**: ~20 cycles barrier synchronization  
4. **Swap**: ~2 cycles bank switching

Expected speedup: ~10-20× vs single-core for large netlists due to parallel evaluation.

## Cross-Partition Signals

For netlists that don't fit on one core:
- Signals crossing partition boundaries use `GATE_REMOTE` 
- Routed via mesh network with XY routing
- Synchronized during propagate phase

## Future Enhancements

- **Convergence detection**: Early termination when state stabilizes
- **Load balancing**: Dynamic gate redistribution
- **Hierarchical partitioning**: Sub-modules mapped to core clusters
- **Event-driven simulation**: Sparse update optimization