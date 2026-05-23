/* rtl_partition.h — Intelligent partitioning of RTL sensitivity lists.
 *
 * Distributes @(posedge clk) events across cores while minimizing
 * cross-partition signal traffic and balancing computational load.
 */

#ifndef RTL_PARTITION_H
#define RTL_PARTITION_H

#include "rtl_sim_engine.h"

// Partitioning strategies
typedef enum {
    PARTITION_ROUND_ROBIN,    // Simple round-robin assignment
    PARTITION_CONNECTIVITY,   // Minimize cross-partition edges
    PARTITION_TIMING,         // Critical path aware
    PARTITION_HIERARCHICAL,   // Module-based assignment
    PARTITION_HYBRID          // Combined heuristics
} partition_strategy_t;

// Graph representation for connectivity analysis
typedef struct {
    uint32_t src_gate;      // Source gate index
    uint32_t dst_gate;      // Destination gate index
    uint32_t signal_idx;    // State vector index
    float weight;           // Edge weight (frequency, criticality)
} signal_edge_t;

typedef struct {
    gate_desc_t *gates;     // Gate array
    uint32_t num_gates;
    signal_edge_t *edges;   // Connectivity graph
    uint32_t num_edges;
    uint32_t state_size;
} netlist_graph_t;

// Partition assignment result
typedef struct {
    uint8_t *gate_to_core;      // gate_to_core[gate_idx] = core_id
    uint32_t *core_gate_count;  // Number of gates per core
    uint32_t cross_edges;       // Number of cross-partition edges
    float load_imbalance;       // Max/min load ratio
    float estimated_speedup;    // Predicted parallel speedup
} partition_result_t;

// Main partitioning interface
int rtl_partition_netlist(netlist_graph_t *graph,
                         partition_strategy_t strategy,
                         uint32_t num_cores,
                         partition_result_t *result);

// Strategy implementations
int partition_round_robin(netlist_graph_t *graph, uint32_t num_cores,
                         partition_result_t *result);
int partition_connectivity(netlist_graph_t *graph, uint32_t num_cores,
                          partition_result_t *result);
int partition_timing_aware(netlist_graph_t *graph, uint32_t num_cores,
                          partition_result_t *result);
int partition_hierarchical(netlist_graph_t *graph, uint32_t num_cores,
                          partition_result_t *result);

// Graph analysis utilities
int build_connectivity_graph(gate_desc_t *gates, uint32_t num_gates,
                             netlist_graph_t *graph);
int analyze_critical_paths(netlist_graph_t *graph, uint32_t *path_lengths);
int detect_modules(netlist_graph_t *graph, uint32_t *module_ids);

// Load balancing
int balance_partitions(partition_result_t *result, uint32_t num_cores);
float calculate_speedup(partition_result_t *result, uint32_t num_cores);

// Visualization and debugging
void print_partition_stats(partition_result_t *result, uint32_t num_cores);
int export_partition_dot(netlist_graph_t *graph, partition_result_t *result,
                        const char *filename);

#endif /* RTL_PARTITION_H */