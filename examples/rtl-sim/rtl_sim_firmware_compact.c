/* rtl_sim_firmware_compact.c — Compact firmware for RTL simulation.
 *
 * Optimized version that fits in 2KB limit for ZCU104 deployment.
 */

#include <stdint.h>

// Memory-mapped register access
static inline uint32_t mesh_coord_reg(void) {
    return *(volatile uint32_t *)0xF0000040;
}

static inline void mesh_push(uint8_t dir, uint32_t data) {
    volatile uint32_t *push_data = (volatile uint32_t *)(0xF0000000 + dir*0x10);
    volatile uint32_t *push_stat = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0x4);
    while (*push_stat & 1) { }
    *push_data = data;
}

static inline uint32_t mesh_pop(uint8_t dir) {
    volatile uint32_t *pop_data = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0x8);
    volatile uint32_t *pop_stat = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0xC);
    while (*pop_stat & 1) { }
    return *pop_data;
}

// Check if this is the master core (1,1)
static inline int is_master_core(void) {
    uint32_t coord = mesh_coord_reg();
    uint8_t my_x = coord & 0x7;
    uint8_t my_y = (coord >> 3) & 0x7;
    return (my_x == 1 && my_y == 1);
}

// Host communication (master core only)
static void host_send(uint32_t data) {
    if (!is_master_core()) return;
    mesh_push(0, data);
}

static uint32_t host_recv(void) {
    if (!is_master_core()) return 0;
    return mesh_pop(0);
}

// Simple gate evaluation
static void evaluate_gates(void) {
    uint8_t *bank_a = (uint8_t *)0x80000000;
    uint8_t *bank_b = (uint8_t *)0x80000800;
    uint32_t *partition = (uint32_t *)0x80001C00;
    uint32_t num_gates = partition[0];
    uint32_t cycle = partition[3] & 1; // bank select

    uint8_t *read_bank = cycle ? bank_b : bank_a;
    uint8_t *write_bank = cycle ? bank_a : bank_b;

    // Simple logic evaluation for demo
    for (uint32_t i = 0; i < num_gates && i < 32; i++) {
        uint8_t input = (i < 256) ? read_bank[i] : 0;
        write_bank[i] = input ^ 1; // Simple NOT gate for demo
    }
}

// Global sync via delay
static void global_sync(void) {
    volatile int delay = 500;
    while (delay-- > 0) { }
}

// Swap memory banks
static void swap_banks(void) {
    uint32_t *partition = (uint32_t *)0x80001C00;
    partition[3]++; // Increment cycle count
}

int main(void) {
    uint32_t coord = mesh_coord_reg();
    uint32_t max_cycles = 40;

    // Wait for start command (master core only)
    if (is_master_core()) {
        uint32_t cmd = host_recv();
        if ((cmd & 0xFFFFFF00) == 0x53494D00) {
            max_cycles = cmd & 0xFF;
        }
    }

    // Initialize partition data
    uint32_t *partition = (uint32_t *)0x80001C00;
    if (partition[0] == 0) {
        partition[0] = 10; // num_gates
        partition[1] = 64; // state_size
        partition[2] = 0;  // num_remotes
        partition[3] = 0;  // cycle_count
    }

    // Main simulation loop
    for (uint32_t cycle = 0; cycle < max_cycles; cycle++) {
        evaluate_gates();
        global_sync();
        swap_banks();
    }

    // Signal completion (master core)
    if (is_master_core()) {
        uint32_t response = 0x444F4E00 | (max_cycles & 0xFF);
        host_send(response);
    }

    // Keep running
    while (1) {
        global_sync();
    }

    return 0;
}