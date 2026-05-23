/* rtl_sim_firmware.c — Firmware that runs on each core for parallel RTL simulation.
 *
 * This is the main program that executes on each VexRiscv core in the mesh.
 * It implements the lock-stepped evaluate/propagate cycle with double-buffered
 * memory for parallel RTL simulation.
 */

#include "rtl_sim_engine.h"

// Coordinate check (only core 0,0 responds to host)
static inline int is_master_core(void) {
    uint32_t coord = *(volatile uint32_t *)0xF0000040;
    uint8_t my_x = coord & 0x7;
    uint8_t my_y = (coord >> 3) & 0x7;
    return (my_x == 1 && my_y == 1); // Logical coordinates (1,1)
}

// Host communication (only master core)
static void host_send(uint32_t data) {
    if (!is_master_core()) return;

    volatile uint32_t *push_data = (volatile uint32_t *)0xF0000000; // EP 0 PUSH_DATA
    volatile uint32_t *push_stat = (volatile uint32_t *)0xF0000004; // EP 0 PUSH_STATUS

    while (*push_stat & 1) { } // Wait for not full
    *push_data = data;
}

static uint32_t host_recv(void) {
    if (!is_master_core()) return 0;

    volatile uint32_t *pop_data = (volatile uint32_t *)0xF0000008; // EP 0 POP_DATA
    volatile uint32_t *pop_stat = (volatile uint32_t *)0xF000000C; // EP 0 POP_STATUS

    while (*pop_stat & 1) { } // Wait for not empty
    return *pop_data;
}

// Wait for simulation start command
static uint32_t wait_for_start(void) {
    if (is_master_core()) {
        uint32_t cmd = host_recv();
        if ((cmd & 0xFFFFFF00) == 0x53494D00) { // 'SIM\0'
            return cmd & 0xFF; // Extract cycle count
        }
    }
    return 0;
}

// Signal simulation completion
static void signal_complete(uint32_t cycles) {
    if (is_master_core()) {
        uint32_t response = 0x444F4E00 | (cycles & 0xFF); // 'DON\0' + cycles
        host_send(response);
    }
}

// Core synchronization primitive (simplified barrier)
static void global_sync(void) {
    // Use a simple delay-based sync for now
    // In a full implementation, this would use mesh communication
    // to implement a proper barrier

    volatile int delay = 1000;
    while (delay-- > 0) { }
}

int main(void) {
    // Initialize simulation engine
    rtl_sim_init();

    // Load partition data from BRAM
    // The host has already written the partition into our memory
    partition_desc_t *partition = (partition_desc_t *)PARTITION_BASE;

    // Simple validation
    if (partition->num_gates > MAX_GATES) {
        // Error: too many gates
        return 1;
    }

    // Wait for start command (only master core listens)
    uint32_t max_cycles = 50; // Default
    if (is_master_core()) {
        max_cycles = wait_for_start();
        if (max_cycles == 0) max_cycles = 50;
    }

    // All cores start simulation simultaneously
    global_sync();

    // Main simulation loop
    for (uint32_t cycle = 0; cycle < max_cycles; cycle++) {
        // Step 1: Evaluate gates (read from current bank, write to next bank)
        evaluate_gates();

        // Step 2: Propagate cross-partition signals via mesh
        // For now, skip cross-partition signals (local simulation only)
        // propagate_signals();

        // Step 3: Synchronize all cores
        global_sync();

        // Step 4: Swap banks
        swap_banks();

        // Early termination check (could implement convergence detection)
        // For now, always run full cycle count
    }

    // Signal completion (only master core)
    signal_complete(max_cycles);

    // Keep running (prevent core from halting)
    while (1) {
        global_sync();
    }

    return 0;
}