/* rtl_sim_host.h — Host-side controller for parallel RTL simulation.
 *
 * Manages the 25-core mesh for lock-stepped RTL simulation:
 *   1. Loads simulation firmware into all cores
 *   2. Partitions netlists across cores
 *   3. Distributes initial state
 *   4. Orchestrates simulation execution
 *   5. Collects final results
 */

#ifndef RTL_SIM_HOST_H
#define RTL_SIM_HOST_H

#include <stdint.h>
#include "rtl_sim_engine.h"

// Host-side mesh interface (via ZCU104 bridge)
#define LDX_BASE   0xA0000000UL
#define LDX_SIZE   0x20000U
#define CTRL_OFF   0x19000      // Core reset control
#define EP_BASE    0x19100      // Endpoint base address
#define EP_STRIDE  0x10         // 16 bytes per endpoint

// Core layout: 5x5 mesh, logical coordinates (1,1) to (5,5)
#define MESH_SIZE  5
#define NUM_CORES  25

// Netlist representation
typedef struct {
    gate_desc_t *gates;
    uint32_t num_gates;
    remote_desc_t *remotes;
    uint32_t num_remotes;
    uint8_t *init_state;
    uint32_t state_size;
    char description[64];
} netlist_t;

// Simulation partition (assigned to one core)
typedef struct {
    uint8_t core_id;           // Target core (0-24)
    uint8_t core_x, core_y;    // Mesh coordinates
    gate_desc_t *gates;        // Gate subset for this core
    uint32_t num_gates;
    remote_desc_t *remotes;    // Cross-partition signals from this core
    uint32_t num_remotes;
    uint8_t *local_state;      // State subset for this core
    uint32_t state_size;
} sim_partition_t;

// Host controller state
typedef struct {
    volatile uint32_t *regs;   // Memory-mapped ZCU104 registers
    netlist_t netlist;         // Full netlist to simulate
    sim_partition_t partitions[NUM_CORES]; // Per-core partitions
    uint32_t total_cycles;     // Simulation length
    uint8_t cores_loaded;      // Number of cores with firmware
    uint8_t simulation_active; // 1 = running, 0 = stopped
} rtl_sim_controller_t;

// Function prototypes

// Initialization
int rtl_sim_host_init(rtl_sim_controller_t *ctrl);
void rtl_sim_host_cleanup(rtl_sim_controller_t *ctrl);

// Firmware management
int rtl_sim_load_firmware(rtl_sim_controller_t *ctrl, const char *firmware_path);
int rtl_sim_reset_cores(rtl_sim_controller_t *ctrl);
int rtl_sim_release_cores(rtl_sim_controller_t *ctrl);

// Netlist operations
int rtl_sim_load_netlist(rtl_sim_controller_t *ctrl, const char *netlist_path);
int rtl_sim_partition_netlist(rtl_sim_controller_t *ctrl);
int rtl_sim_distribute_partitions(rtl_sim_controller_t *ctrl);

// Simulation control
int rtl_sim_start(rtl_sim_controller_t *ctrl, uint32_t max_cycles);
int rtl_sim_stop(rtl_sim_controller_t *ctrl);
int rtl_sim_wait_complete(rtl_sim_controller_t *ctrl);

// Result collection
int rtl_sim_collect_results(rtl_sim_controller_t *ctrl, uint8_t **final_state, uint32_t *state_size);
void rtl_sim_print_stats(rtl_sim_controller_t *ctrl);

// Internal helpers
static inline uint32_t core_linear_id(uint8_t x, uint8_t y) {
    return x * MESH_SIZE + y;
}

static inline void linear_to_coords(uint32_t linear_id, uint8_t *x, uint8_t *y) {
    *x = linear_id / MESH_SIZE;
    *y = linear_id % MESH_SIZE;
}

// Memory-mapped register access
static inline uint32_t host_rd(rtl_sim_controller_t *ctrl, uint32_t off) {
    return ctrl->regs[off >> 2];
}

static inline void host_wr(rtl_sim_controller_t *ctrl, uint32_t off, uint32_t val) {
    ctrl->regs[off >> 2] = val;
}

// Endpoint communication
int ep_push_blocking(rtl_sim_controller_t *ctrl, unsigned ep, uint32_t data);
uint32_t ep_pop_blocking(rtl_sim_controller_t *ctrl, unsigned ep);

#endif /* RTL_SIM_HOST_H */