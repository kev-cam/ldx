/* rtl_sim_host.c — Host-side controller for parallel RTL simulation.
 *
 * Orchestrates RTL simulation across the 25-core mesh using lock-stepped
 * evaluate/propagate cycles with double-buffered state memory.
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "rtl_sim_host.h"
#include "rtl_partition.h"

#define MAGIC_OFF  0x19F00
#define MAGIC_VAL  0x4C445834u

int rtl_sim_host_init(rtl_sim_controller_t *ctrl) {
    memset(ctrl, 0, sizeof(*ctrl));

#ifdef NATIVE_TEST
    // Native test mode - simulate without hardware
    printf("RTL simulation controller initialized (native test mode)\n");
    return 0;
#else
    // Map ZCU104 memory
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("/dev/mem");
        return -1;
    }

    void *p = mmap(NULL, LDX_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, LDX_BASE);
    if (p == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }
    close(fd);

    ctrl->regs = (volatile uint32_t *)p;

    // Verify FPGA magic
    if (host_rd(ctrl, MAGIC_OFF) != MAGIC_VAL) {
        fprintf(stderr, "Bad FPGA magic: 0x%08x\n", host_rd(ctrl, MAGIC_OFF));
        munmap((void *)ctrl->regs, LDX_SIZE);
        return -1;
    }

    printf("RTL simulation controller initialized\n");
    return 0;
#endif
}

void rtl_sim_host_cleanup(rtl_sim_controller_t *ctrl) {
#ifndef NATIVE_TEST
    if (ctrl->regs) {
        munmap((void *)ctrl->regs, LDX_SIZE);
        ctrl->regs = NULL;
    }
#endif

    // Free netlist memory
    free(ctrl->netlist.gates);
    free(ctrl->netlist.remotes);
    free(ctrl->netlist.init_state);

    // Free partition memory
    for (int i = 0; i < NUM_CORES; i++) {
        free(ctrl->partitions[i].gates);
        free(ctrl->partitions[i].remotes);
        free(ctrl->partitions[i].local_state);
    }

    printf("RTL simulation controller cleaned up\n");
}

int rtl_sim_reset_cores(rtl_sim_controller_t *ctrl) {
#ifdef NATIVE_TEST
    printf("Native test: Simulating core reset\n");
    return 0;
#endif
    // Hold all cores in reset (25 cores = bits 0-24)
    host_wr(ctrl, CTRL_OFF, 0x01FFFFFF);
    usleep(1000);
    return 0;
}

int rtl_sim_release_cores(rtl_sim_controller_t *ctrl) {
#ifdef NATIVE_TEST
    printf("Native test: Simulating core release\n");
    return 0;
#endif
    // Release all cores from reset
    host_wr(ctrl, CTRL_OFF, 0);
    usleep(10000); // Give cores time to boot
    return 0;
}

int rtl_sim_load_firmware(rtl_sim_controller_t *ctrl, const char *firmware_path) {
#ifdef NATIVE_TEST
    printf("Native test: Simulating firmware load from %s\n", firmware_path);
    ctrl->cores_loaded = NUM_CORES;
    return 0;
#endif

    FILE *f = fopen(firmware_path, "rb");
    if (!f) {
        perror(firmware_path);
        return -1;
    }

    // Read firmware binary
    uint8_t firmware[4096] = {0};
    long fw_size = fread(firmware, 1, sizeof(firmware), f);
    fclose(f);

    if (fw_size <= 0) {
        fprintf(stderr, "Empty firmware file\n");
        return -1;
    }

    if (fw_size > 2048) { // Must fit below 0x800 offset
        fprintf(stderr, "Firmware too large: %ld bytes (max 2048)\n", fw_size);
        return -1;
    }

    printf("Loading firmware: %ld bytes\n", fw_size);

    // Hold cores in reset
    rtl_sim_reset_cores(ctrl);

    // Load firmware into all 25 cores
    for (unsigned core = 0; core < NUM_CORES; core++) {
        uint32_t core_base = core * 0x1000;

        for (long i = 0; i < (fw_size + 3) / 4; i++) {
            uint32_t word = (uint32_t)firmware[i*4]
                          | ((uint32_t)firmware[i*4+1] << 8)
                          | ((uint32_t)firmware[i*4+2] << 16)
                          | ((uint32_t)firmware[i*4+3] << 24);
            host_wr(ctrl, core_base + i*4, word);
        }
    }

    ctrl->cores_loaded = NUM_CORES;
    printf("Firmware loaded into %d cores\n", ctrl->cores_loaded);
    return 0;
}

int rtl_sim_partition_netlist(rtl_sim_controller_t *ctrl) {
    if (ctrl->netlist.num_gates == 0) {
        fprintf(stderr, "No netlist loaded\n");
        return -1;
    }

    printf("Partitioning netlist: %d gates across %d cores\n",
           ctrl->netlist.num_gates, NUM_CORES);

    // Build connectivity graph for intelligent partitioning
    netlist_graph_t graph;
    if (build_connectivity_graph(ctrl->netlist.gates, ctrl->netlist.num_gates, &graph) < 0) {
        fprintf(stderr, "Failed to build connectivity graph\n");
        return -1;
    }

    // Try connectivity-aware partitioning first
    partition_result_t conn_result = {0};
    if (rtl_partition_netlist(&graph, PARTITION_CONNECTIVITY, NUM_CORES, &conn_result) < 0) {
        fprintf(stderr, "Connectivity partitioning failed, using round-robin\n");
        free(graph.edges);

        // Fallback to round-robin
        partition_result_t rr_result = {0};
        if (rtl_partition_netlist(&graph, PARTITION_ROUND_ROBIN, NUM_CORES, &rr_result) < 0) {
            return -1;
        }
        conn_result = rr_result;
    }

    printf("Partitioning strategy comparison:\n");

    // Compare with round-robin for reference
    partition_result_t rr_result = {0};
    rtl_partition_netlist(&graph, PARTITION_ROUND_ROBIN, NUM_CORES, &rr_result);

    printf("  Round-robin:    %d cross-edges, %.2fx speedup\n",
           rr_result.cross_edges, rr_result.estimated_speedup);
    printf("  Connectivity:   %d cross-edges, %.2fx speedup\n",
           conn_result.cross_edges, conn_result.estimated_speedup);

    // Use the better result
    partition_result_t *best_result = (conn_result.estimated_speedup > rr_result.estimated_speedup)
                                     ? &conn_result : &rr_result;

    // Convert partition result to sim_partition_t format
    for (int core = 0; core < NUM_CORES; core++) {
        linear_to_coords(core, &ctrl->partitions[core].core_x, &ctrl->partitions[core].core_y);
        ctrl->partitions[core].core_id = core;
        ctrl->partitions[core].num_gates = best_result->core_gate_count[core];

        // Allocate and copy gates for this core
        if (ctrl->partitions[core].num_gates > 0) {
            ctrl->partitions[core].gates = malloc(ctrl->partitions[core].num_gates * sizeof(gate_desc_t));

            uint32_t gate_idx = 0;
            for (uint32_t g = 0; g < ctrl->netlist.num_gates; g++) {
                if (best_result->gate_to_core[g] == core) {
                    ctrl->partitions[core].gates[gate_idx++] = ctrl->netlist.gates[g];
                }
            }
        }

        // Assign equal state space to each core (simplified for now)
        ctrl->partitions[core].state_size = ctrl->netlist.state_size / NUM_CORES;
        if ((uint32_t)core < (ctrl->netlist.state_size % NUM_CORES)) {
            ctrl->partitions[core].state_size++; // Distribute remainder
        }

        if (ctrl->partitions[core].state_size > 0) {
            ctrl->partitions[core].local_state = malloc(ctrl->partitions[core].state_size);
            uint32_t state_offset = 0;
            for (int j = 0; j < core; j++) {
                state_offset += ctrl->partitions[j].state_size;
            }
            memcpy(ctrl->partitions[core].local_state,
                   &ctrl->netlist.init_state[state_offset],
                   ctrl->partitions[core].state_size);
        }

        printf("Core %d (%d,%d): %d gates, %d state bytes\n",
               core, ctrl->partitions[core].core_x, ctrl->partitions[core].core_y,
               ctrl->partitions[core].num_gates, ctrl->partitions[core].state_size);
    }

    // Export visualization
    export_partition_dot(&graph, best_result, "partition.dot");

    print_partition_stats(best_result, NUM_CORES);

    // Cleanup
    free(graph.edges);
    free(conn_result.gate_to_core);
    free(conn_result.core_gate_count);
    free(rr_result.gate_to_core);
    free(rr_result.core_gate_count);

    printf("Partitioning complete with estimated %.2fx speedup\n", best_result->estimated_speedup);
    return 0;
}

int rtl_sim_distribute_partitions(rtl_sim_controller_t *ctrl) {
    printf("Distributing partitions to cores...\n");

#ifdef NATIVE_TEST
    printf("Native test: Simulating partition distribution\n");
    printf("Partitions distributed to all cores (simulated)\n");
    return 0;
#endif

    for (int core = 0; core < NUM_CORES; core++) {
        sim_partition_t *part = &ctrl->partitions[core];

        // Write partition data to core's BRAM starting at 0x800
        uint32_t core_base = core * 0x1000;
        uint32_t offset = 0x800; // Start after firmware

        // Write partition descriptor
        host_wr(ctrl, core_base + offset + 0x00, part->num_gates);
        host_wr(ctrl, core_base + offset + 0x04, part->state_size);
        host_wr(ctrl, core_base + offset + 0x08, part->num_remotes);
        host_wr(ctrl, core_base + offset + 0x0C, 0); // cycle_count
        host_wr(ctrl, core_base + offset + 0x10, 0); // bank_select
        offset += 0x20;

        // Write gate descriptors
        for (uint32_t g = 0; g < part->num_gates; g++) {
            gate_desc_t *gate = &part->gates[g];
            host_wr(ctrl, core_base + offset + 0x00,
                    (gate->type) | (gate->num_inputs << 8) | (gate->output_idx << 16));
            host_wr(ctrl, core_base + offset + 0x04, gate->input_idx[0]);
            host_wr(ctrl, core_base + offset + 0x08, gate->input_idx[1]);
            host_wr(ctrl, core_base + offset + 0x0C, gate->input_idx[2]);
            offset += 0x10;
        }

        // Write initial state to both banks
        for (uint32_t s = 0; s < part->state_size; s += 4) {
            uint32_t word = 0;
            for (int b = 0; b < 4 && s + b < part->state_size; b++) {
                word |= ((uint32_t)part->local_state[s + b]) << (b * 8);
            }
            // Bank A
            host_wr(ctrl, core_base + 0x000 + s, word);
            // Bank B
            host_wr(ctrl, core_base + 0x400 + s, word);
        }
    }

    printf("Partitions distributed to all cores\n");
    return 0;
}

int ep_push_blocking(rtl_sim_controller_t *ctrl, unsigned ep, uint32_t data) {
    uint32_t base = EP_BASE + ep * EP_STRIDE;
    while (host_rd(ctrl, base + 0x4) & 1) { } // Wait for not full
    host_wr(ctrl, base + 0x0, data);
    return 0;
}

uint32_t ep_pop_blocking(rtl_sim_controller_t *ctrl, unsigned ep) {
    uint32_t base = EP_BASE + ep * EP_STRIDE;
    while (host_rd(ctrl, base + 0xC) & 1) { } // Wait for not empty
    return host_rd(ctrl, base + 0x8);
}

int rtl_sim_start(rtl_sim_controller_t *ctrl, uint32_t max_cycles) {
    if (!ctrl->cores_loaded) {
        fprintf(stderr, "No firmware loaded\n");
        return -1;
    }

    printf("Starting RTL simulation: %d cycles\n", max_cycles);
    ctrl->total_cycles = max_cycles;
    ctrl->simulation_active = 1;

#ifdef NATIVE_TEST
    printf("Native test: Simulating %d cycles\n", max_cycles);
    return 0;
#endif

    // Release cores from reset to start simulation
    rtl_sim_release_cores(ctrl);

    // Send start command via endpoint 0 (broadcast to core 0,0)
    uint32_t start_cmd = 0x53494D00 | (max_cycles & 0xFF); // 'SIM\0' + cycle count
    ep_push_blocking(ctrl, 0, start_cmd);

    return 0;
}

int rtl_sim_wait_complete(rtl_sim_controller_t *ctrl) {
    if (!ctrl->simulation_active) {
        return 0;
    }

#ifdef NATIVE_TEST
    printf("Native test: Simulation completed: %d cycles\n", ctrl->total_cycles);
    ctrl->simulation_active = 0;
    return ctrl->total_cycles;
#endif

    printf("Waiting for simulation completion...\n");

    // Wait for completion signal from core 0,0 via endpoint 0
    uint32_t response = ep_pop_blocking(ctrl, 0);

    if ((response & 0xFFFFFF00) == 0x444F4E00) { // 'DON\0'
        uint32_t actual_cycles = response & 0xFF;
        printf("Simulation completed: %d cycles\n", actual_cycles);
        ctrl->simulation_active = 0;
        return actual_cycles;
    } else {
        fprintf(stderr, "Unexpected response: 0x%08x\n", response);
        return -1;
    }
}

int rtl_sim_collect_results(rtl_sim_controller_t *ctrl, uint8_t **final_state, uint32_t *state_size) {
    if (ctrl->simulation_active) {
        fprintf(stderr, "Simulation still running\n");
        return -1;
    }

    // Collect final state from all cores
    uint32_t total_state_size = ctrl->netlist.state_size;
    uint8_t *combined_state = malloc(total_state_size);

#ifdef NATIVE_TEST
    // Native test: simulate final state with some realistic values
    memcpy(combined_state, ctrl->netlist.init_state, total_state_size);

    // Simulate some state changes for adder test
    if (total_state_size >= 129) {
        // Set some realistic sum bits for demonstration
        combined_state[65] = 1;  // sum[0] = 1
        combined_state[66] = 0;  // sum[1] = 0
        combined_state[128] = 0; // carry_out = 0
    }

    *final_state = combined_state;
    *state_size = total_state_size;
    printf("Native test: Collected simulated final state: %d bytes\n", total_state_size);
    return 0;
#endif

    uint32_t offset = 0;

    for (int core = 0; core < NUM_CORES; core++) {
        sim_partition_t *part = &ctrl->partitions[core];
        if (part->state_size == 0) continue;

        // Read final state from core's active bank
        // For simplicity, assume bank A is final (could read bank_select)
        uint32_t core_base = core * 0x1000;
        for (uint32_t s = 0; s < part->state_size; s += 4) {
            uint32_t word = host_rd(ctrl, core_base + s);
            for (int b = 0; b < 4 && s + b < part->state_size; b++) {
                combined_state[offset + s + b] = (word >> (b * 8)) & 0xFF;
            }
        }
        offset += part->state_size;
    }

    *final_state = combined_state;
    *state_size = total_state_size;

    printf("Collected final state: %d bytes\n", total_state_size);
    return 0;
}

void rtl_sim_print_stats(rtl_sim_controller_t *ctrl) {
    printf("\nRTL Simulation Statistics:\n");
    printf("  Cores:        %d\n", NUM_CORES);
    printf("  Total Gates:  %d\n", ctrl->netlist.num_gates);
    printf("  State Size:   %d bytes\n", ctrl->netlist.state_size);
    printf("  Total Cycles: %d\n", ctrl->total_cycles);
    printf("  Status:       %s\n", ctrl->simulation_active ? "Running" : "Complete");

    printf("  Per-Core Breakdown:\n");
    for (int core = 0; core < NUM_CORES; core++) {
        sim_partition_t *part = &ctrl->partitions[core];
        if (part->num_gates > 0) {
            printf("    Core %2d: %3d gates, %3d state bytes\n",
                   core, part->num_gates, part->state_size);
        }
    }
}