/* rtl_multiclk.h — Multi-clock domain support for parallel RTL simulation.
 *
 * Extends the sensitivity list partitioning to handle multiple clock domains:
 *   - @(posedge clk_sys) - System clock domain
 *   - @(posedge clk_mem) - Memory interface clock
 *   - @(posedge clk_pcie) - PCIe interface clock
 *   - etc.
 *
 * Each clock domain gets its own set of cores and evaluation schedule.
 */

#ifndef RTL_MULTICLK_H
#define RTL_MULTICLK_H

#include "rtl_sim_engine.h"

// Clock domain descriptor
typedef struct {
    uint8_t domain_id;        // Clock domain ID (0-7)
    uint32_t period_ns;       // Clock period in nanoseconds
    uint32_t phase_offset;    // Phase offset from simulation start
    uint8_t core_start;       // First core assigned to this domain
    uint8_t core_count;       // Number of cores for this domain
    uint32_t num_gates;       // Gates in this clock domain
    char domain_name[16];     // Human-readable name
} clock_domain_t;

// Multi-clock simulation state
typedef struct {
    clock_domain_t domains[8];  // Up to 8 clock domains
    uint8_t num_domains;        // Active domain count
    uint64_t sim_time_ns;      // Current simulation time
    uint8_t *gate_to_domain;   // Map gates to clock domains
    uint32_t total_gates;      // Total gates across all domains
} multiclk_sim_t;

// Clock domain assignment strategies
typedef enum {
    CLK_ASSIGN_ROUND_ROBIN,   // Distribute domains across cores evenly
    CLK_ASSIGN_FREQUENCY,     // Fast clocks get more cores
    CLK_ASSIGN_COMPLEXITY,    // Complex domains get more cores
    CLK_ASSIGN_HIERARCHY      // Module-based domain assignment
} clk_assign_strategy_t;

// Multi-clock simulation interface
int multiclk_init(multiclk_sim_t *sim, uint32_t num_cores);
int multiclk_add_domain(multiclk_sim_t *sim, const char *name,
                       uint32_t period_ns, uint32_t phase_offset);
int multiclk_assign_gates(multiclk_sim_t *sim, gate_desc_t *gates,
                         uint32_t num_gates, clk_assign_strategy_t strategy);
int multiclk_schedule_domains(multiclk_sim_t *sim, uint32_t num_cores);

// Simulation execution for multi-clock
int multiclk_step(multiclk_sim_t *sim, uint64_t target_time_ns);
int multiclk_run(multiclk_sim_t *sim, uint64_t duration_ns);

// Clock domain utilities
int detect_clock_domains(gate_desc_t *gates, uint32_t num_gates,
                        multiclk_sim_t *sim);
int optimize_domain_assignment(multiclk_sim_t *sim, uint32_t num_cores);
void print_multiclk_stats(multiclk_sim_t *sim);

// Clock-aware partitioning
int partition_by_clock_domain(gate_desc_t *gates, uint32_t num_gates,
                             multiclk_sim_t *sim, uint8_t *gate_to_core);

#endif /* RTL_MULTICLK_H */