/* rtl_sim_engine.c — Lock-stepped parallel RTL simulation engine.
 *
 * This runs on each VexRiscv softcore in the 5×5 mesh. Each core evaluates
 * its assigned gate partition in lock-step with all other cores.
 */

#include "rtl_sim_engine.h"

// Memory-mapped register access
static inline uint32_t mesh_coord_reg(void) {
    return *(volatile uint32_t *)0xF0000040;
}

static inline void mesh_push(uint8_t dir, uint32_t data) {
    volatile uint32_t *push_data = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0x0);
    volatile uint32_t *push_stat = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0x4);
    while (*push_stat & 1) { } // Wait for FIFO not full
    *push_data = data;
}

static inline uint32_t mesh_pop(uint8_t dir) {
    volatile uint32_t *pop_data = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0x8);
    volatile uint32_t *pop_stat = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0xC);
    while (*pop_stat & 1) { } // Wait for FIFO not empty
    return *pop_data;
}

static inline int mesh_pop_try(uint8_t dir, uint32_t *data) {
    volatile uint32_t *pop_data = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0x8);
    volatile uint32_t *pop_stat = (volatile uint32_t *)(0xF0000000 + dir*0x10 + 0xC);
    if (*pop_stat & 1) return 0; // Empty
    *data = *pop_data;
    return 1;
}

// Global state
static core_state_t g_core;
static partition_desc_t *g_partition = (partition_desc_t *)PARTITION_BASE;
static gate_desc_t *g_gates = (gate_desc_t *)GATE_BASE;
static remote_desc_t *g_remotes = (remote_desc_t *)REMOTE_BASE;

void rtl_sim_init(void) {
    uint32_t coord = mesh_coord_reg();
    g_core.my_x = coord & 0x7;
    g_core.my_y = (coord >> 3) & 0x7;
    g_core.core_id = g_core.my_x * 5 + g_core.my_y;
    g_core.active_bank = 0;
    g_core.cycle = 0;
    g_core.barrier_token = 0;

    // Initialize partition descriptor
    g_partition->num_gates = 0;
    g_partition->num_states = 0;
    g_partition->num_remotes = 0;
    g_partition->cycle_count = 0;
    g_partition->bank_select = 0;
}

void rtl_sim_load_partition(const gate_desc_t *gates, uint32_t num_gates,
                           const remote_desc_t *remotes, uint32_t num_remotes,
                           const uint8_t *init_state, uint32_t state_size) {
    // Copy gate descriptors
    for (uint32_t i = 0; i < num_gates && i < MAX_GATES; i++) {
        g_gates[i] = gates[i];
    }

    // Copy remote signal descriptors
    for (uint32_t i = 0; i < num_remotes && i < MAX_REMOTES; i++) {
        g_remotes[i] = remotes[i];
    }

    // Initialize state vectors (both banks with same initial state)
    uint8_t *bank_a = (uint8_t *)BANK_A_BASE;
    uint8_t *bank_b = (uint8_t *)BANK_B_BASE;
    for (uint32_t i = 0; i < state_size && i < STATE_SIZE; i++) {
        bank_a[i] = init_state[i];
        bank_b[i] = init_state[i];
    }

    // Update partition descriptor
    g_partition->num_gates = num_gates;
    g_partition->num_states = state_size;
    g_partition->num_remotes = num_remotes;
    g_partition->cycle_count = 0;
    g_partition->bank_select = 0;
}

void evaluate_gates(void) {
    uint8_t *read_bank = (uint8_t *)(g_core.active_bank ? BANK_B_BASE : BANK_A_BASE);
    uint8_t *write_bank = (uint8_t *)(g_core.active_bank ? BANK_A_BASE : BANK_B_BASE);

    for (uint32_t i = 0; i < g_partition->num_gates; i++) {
        gate_desc_t *gate = &g_gates[i];
        uint8_t inputs[4] = {0};
        uint8_t output = 0;

        // Read inputs from current bank
        for (uint8_t j = 0; j < gate->num_inputs && j < 4; j++) {
            uint32_t idx = gate->input_idx[j];
            if (idx < g_partition->num_states) {
                inputs[j] = read_bank[idx];
            }
        }

        // Evaluate gate function
        switch (gate->type) {
            case GATE_AND:
                output = (gate->num_inputs >= 2) ? (inputs[0] & inputs[1]) : inputs[0];
                for (uint8_t j = 2; j < gate->num_inputs; j++) {
                    output &= inputs[j];
                }
                break;

            case GATE_OR:
                output = (gate->num_inputs >= 2) ? (inputs[0] | inputs[1]) : inputs[0];
                for (uint8_t j = 2; j < gate->num_inputs; j++) {
                    output |= inputs[j];
                }
                break;

            case GATE_XOR:
                output = (gate->num_inputs >= 2) ? (inputs[0] ^ inputs[1]) : inputs[0];
                for (uint8_t j = 2; j < gate->num_inputs; j++) {
                    output ^= inputs[j];
                }
                break;

            case GATE_NOT:
                output = ~inputs[0];
                break;

            case GATE_BUF:
                output = inputs[0];
                break;

            case GATE_DFF:
                // D flip-flop: output = input on clock edge (always active here)
                output = inputs[0];
                break;

            case GATE_REMOTE:
                // Remote signals handled in propagate_signals()
                output = read_bank[gate->output_idx];
                break;

            default:
                output = 0;
                break;
        }

        // Write output to next bank
        if (gate->output_idx < g_partition->num_states) {
            write_bank[gate->output_idx] = output;
        }
    }
}

void propagate_signals(void) {
    uint8_t *current_bank = (uint8_t *)(g_core.active_bank ? BANK_B_BASE : BANK_A_BASE);

    // Send remote signals to other cores
    for (uint32_t i = 0; i < g_partition->num_remotes; i++) {
        remote_desc_t *remote = &g_remotes[i];

        // Read signal value from current bank
        uint8_t value = 0;
        if (remote->target_idx < g_partition->num_states) {
            value = current_bank[remote->target_idx];
        }

        // Route to target core via mesh
        route_signal(remote->target_core, remote->target_idx, value);
    }

    // Receive remote signals from other cores
    for (uint8_t dir = 0; dir < 4; dir++) {
        uint32_t msg_data;
        while (mesh_pop_try(dir, &msg_data)) {
            mesh_msg_t *msg = (mesh_msg_t *)&msg_data;
            if (msg->type == MSG_TYPE_SIGNAL) {
                // Extract target index and value from message
                uint16_t target_idx = (msg->data >> 16) & 0xFFFF;
                uint8_t value = msg->data & 0xFF;

                // Write to next bank
                uint8_t *write_bank = (uint8_t *)(g_core.active_bank ? BANK_A_BASE : BANK_B_BASE);
                if (target_idx < g_partition->num_states) {
                    write_bank[target_idx] = value;
                }
            }
        }
    }
}

void route_signal(uint16_t target_core, uint16_t target_idx, uint8_t value) {
    if (target_core >= 25) return; // Invalid core

    uint8_t target_x = target_core / 5;
    uint8_t target_y = target_core % 5;

    // Simple XY routing: route X first, then Y
    uint8_t dir;
    if (target_x > g_core.my_x) {
        dir = 1; // East
    } else if (target_x < g_core.my_x) {
        dir = 3; // West
    } else if (target_y > g_core.my_y) {
        dir = 0; // North
    } else if (target_y < g_core.my_y) {
        dir = 2; // South
    } else {
        return; // Same core, no routing needed
    }

    // Pack message: type | (target_idx << 16) | value
    mesh_msg_t msg = {
        .type = MSG_TYPE_SIGNAL,
        .data = (target_idx << 16) | value
    };

    mesh_push(dir, *(uint32_t *)&msg);
}

void sync_barrier(void) {
    // Increment local barrier token
    g_core.barrier_token++;

    // Send sync message to all neighbors
    mesh_msg_t sync_msg = {
        .type = MSG_TYPE_SYNC,
        .data = g_core.barrier_token
    };

    for (uint8_t dir = 0; dir < 4; dir++) {
        mesh_push(dir, *(uint32_t *)&sync_msg);
    }

    // Wait for sync responses from all neighbors
    uint8_t sync_count = 0;
    uint8_t expected_neighbors = 4; // Simplified: assume all cores have 4 neighbors

    while (sync_count < expected_neighbors) {
        for (uint8_t dir = 0; dir < 4; dir++) {
            uint32_t msg_data;
            if (mesh_pop_try(dir, &msg_data)) {
                mesh_msg_t *msg = (mesh_msg_t *)&msg_data;
                if (msg->type == MSG_TYPE_SYNC && msg->data == g_core.barrier_token) {
                    sync_count++;
                }
            }
        }
    }
}

void swap_banks(void) {
    g_core.active_bank = 1 - g_core.active_bank;
    g_partition->bank_select = g_core.active_bank;
    g_core.cycle++;
    g_partition->cycle_count = g_core.cycle;
}

void rtl_sim_step(void) {
    // Single simulation step: evaluate → propagate → sync → swap
    evaluate_gates();
    propagate_signals();
    sync_barrier();
    swap_banks();
}

void rtl_sim_run(uint32_t max_cycles) {
    for (uint32_t cycle = 0; cycle < max_cycles; cycle++) {
        rtl_sim_step();

        // Check for early termination conditions
        // (could add convergence detection here)
    }
}

uint8_t *rtl_sim_get_state(void) {
    return (uint8_t *)(g_core.active_bank ? BANK_B_BASE : BANK_A_BASE);
}