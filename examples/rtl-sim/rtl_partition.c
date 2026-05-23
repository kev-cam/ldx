/* rtl_partition.c — Intelligent partitioning algorithms for RTL simulation.
 *
 * Implements various strategies to distribute sensitivity list elements
 * across cores while optimizing for performance.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <limits.h>

#include "rtl_partition.h"

int build_connectivity_graph(gate_desc_t *gates, uint32_t num_gates,
                             netlist_graph_t *graph) {
    // Count edges first
    uint32_t edge_count = 0;
    for (uint32_t i = 0; i < num_gates; i++) {
        edge_count += gates[i].num_inputs;
    }

    graph->gates = gates;
    graph->num_gates = num_gates;
    graph->edges = malloc(edge_count * sizeof(signal_edge_t));
    graph->num_edges = 0;

    // Build adjacency list
    for (uint32_t dst = 0; dst < num_gates; dst++) {
        gate_desc_t *gate = &gates[dst];

        for (uint8_t inp = 0; inp < gate->num_inputs && inp < 3; inp++) {
            uint32_t signal = gate->input_idx[inp];

            // Find source gate that drives this signal
            for (uint32_t src = 0; src < num_gates; src++) {
                if (gates[src].output_idx == signal) {
                    signal_edge_t *edge = &graph->edges[graph->num_edges++];
                    edge->src_gate = src;
                    edge->dst_gate = dst;
                    edge->signal_idx = signal;
                    edge->weight = 1.0f; // Default weight
                    break;
                }
            }
        }
    }

    printf("Built connectivity graph: %d gates, %d edges\n",
           graph->num_gates, graph->num_edges);
    return 0;
}

int partition_round_robin(netlist_graph_t *graph, uint32_t num_cores,
                         partition_result_t *result) {
    result->gate_to_core = malloc(graph->num_gates * sizeof(uint8_t));
    result->core_gate_count = calloc(num_cores, sizeof(uint32_t));

    // Simple round-robin assignment
    for (uint32_t gate = 0; gate < graph->num_gates; gate++) {
        uint8_t core = gate % num_cores;
        result->gate_to_core[gate] = core;
        result->core_gate_count[core]++;
    }

    // Count cross-partition edges
    result->cross_edges = 0;
    for (uint32_t e = 0; e < graph->num_edges; e++) {
        signal_edge_t *edge = &graph->edges[e];
        uint8_t src_core = result->gate_to_core[edge->src_gate];
        uint8_t dst_core = result->gate_to_core[edge->dst_gate];
        if (src_core != dst_core) {
            result->cross_edges++;
        }
    }

    // Calculate load imbalance
    uint32_t max_load = 0, min_load = UINT32_MAX;
    for (uint32_t c = 0; c < num_cores; c++) {
        if (result->core_gate_count[c] > max_load) max_load = result->core_gate_count[c];
        if (result->core_gate_count[c] < min_load) min_load = result->core_gate_count[c];
    }
    result->load_imbalance = min_load ? (float)max_load / min_load : 1.0f;

    printf("Round-robin partition: %d cross-edges, %.2f imbalance\n",
           result->cross_edges, result->load_imbalance);
    return 0;
}

int partition_connectivity(netlist_graph_t *graph, uint32_t num_cores,
                          partition_result_t *result) {
    result->gate_to_core = malloc(graph->num_gates * sizeof(uint8_t));
    result->core_gate_count = calloc(num_cores, sizeof(uint32_t));

    // Initialize all gates to core 0
    memset(result->gate_to_core, 0, graph->num_gates);

    // Greedy assignment: try to keep connected gates together
    uint8_t *visited = calloc(graph->num_gates, 1);

    for (uint32_t start_gate = 0; start_gate < graph->num_gates; start_gate++) {
        if (visited[start_gate]) continue;

        // Find least loaded core
        uint8_t target_core = 0;
        for (uint8_t c = 1; c < num_cores; c++) {
            if (result->core_gate_count[c] < result->core_gate_count[target_core]) {
                target_core = c;
            }
        }

        // BFS to assign connected component to target_core
        uint32_t *queue = malloc(graph->num_gates * sizeof(uint32_t));
        uint32_t head = 0, tail = 0;
        uint32_t cluster_size = 0;
        uint32_t max_cluster = graph->num_gates / num_cores + 1;

        queue[tail++] = start_gate;
        visited[start_gate] = 1;

        while (head < tail && cluster_size < max_cluster) {
            uint32_t current = queue[head++];
            result->gate_to_core[current] = target_core;
            result->core_gate_count[target_core]++;
            cluster_size++;

            // Add connected gates to queue
            for (uint32_t e = 0; e < graph->num_edges; e++) {
                signal_edge_t *edge = &graph->edges[e];
                uint32_t next_gate = UINT32_MAX;

                if (edge->src_gate == current && !visited[edge->dst_gate]) {
                    next_gate = edge->dst_gate;
                } else if (edge->dst_gate == current && !visited[edge->src_gate]) {
                    next_gate = edge->src_gate;
                }

                if (next_gate != UINT32_MAX && !visited[next_gate]) {
                    visited[next_gate] = 1;
                    queue[tail++] = next_gate;
                }
            }
        }

        free(queue);
    }

    free(visited);

    // Count cross-partition edges
    result->cross_edges = 0;
    for (uint32_t e = 0; e < graph->num_edges; e++) {
        signal_edge_t *edge = &graph->edges[e];
        uint8_t src_core = result->gate_to_core[edge->src_gate];
        uint8_t dst_core = result->gate_to_core[edge->dst_gate];
        if (src_core != dst_core) {
            result->cross_edges++;
        }
    }

    // Calculate load imbalance
    uint32_t max_load = 0, min_load = UINT32_MAX;
    for (uint32_t c = 0; c < num_cores; c++) {
        if (result->core_gate_count[c] > max_load) max_load = result->core_gate_count[c];
        if (result->core_gate_count[c] < min_load) min_load = result->core_gate_count[c];
    }
    result->load_imbalance = min_load ? (float)max_load / min_load : 1.0f;

    printf("Connectivity-aware partition: %d cross-edges, %.2f imbalance\n",
           result->cross_edges, result->load_imbalance);
    return 0;
}

float calculate_speedup(partition_result_t *result, uint32_t num_cores) {
    // Simplified speedup model:
    // T_parallel = T_seq / num_cores + cross_edge_penalty + sync_overhead

    float parallel_efficiency = 0.85f; // Account for sync overhead
    float cross_edge_penalty = result->cross_edges * 0.001f; // Cost per remote signal

    // Amdahl's law with communication overhead
    float speedup = 1.0f / ((1.0f / num_cores) + cross_edge_penalty);
    speedup *= parallel_efficiency;

    return speedup;
}

int rtl_partition_netlist(netlist_graph_t *graph,
                         partition_strategy_t strategy,
                         uint32_t num_cores,
                         partition_result_t *result) {
    int ret = -1;

    switch (strategy) {
        case PARTITION_ROUND_ROBIN:
            ret = partition_round_robin(graph, num_cores, result);
            break;

        case PARTITION_CONNECTIVITY:
            ret = partition_connectivity(graph, num_cores, result);
            break;

        case PARTITION_TIMING:
            // TODO: Implement timing-aware partitioning
            printf("Timing-aware partitioning not implemented, using connectivity\n");
            ret = partition_connectivity(graph, num_cores, result);
            break;

        default:
            printf("Unknown partitioning strategy, using round-robin\n");
            ret = partition_round_robin(graph, num_cores, result);
            break;
    }

    if (ret == 0) {
        result->estimated_speedup = calculate_speedup(result, num_cores);
    }

    return ret;
}

void print_partition_stats(partition_result_t *result, uint32_t num_cores) {
    printf("\nPartition Statistics:\n");
    printf("  Cross-partition edges: %d\n", result->cross_edges);
    printf("  Load imbalance ratio:  %.2f\n", result->load_imbalance);
    printf("  Estimated speedup:     %.2fx\n", result->estimated_speedup);

    printf("  Per-core gate counts:\n");
    for (uint32_t c = 0; c < num_cores; c++) {
        printf("    Core %2d: %3d gates\n", c, result->core_gate_count[c]);
    }
}

int export_partition_dot(netlist_graph_t *graph, partition_result_t *result,
                        const char *filename) {
    FILE *f = fopen(filename, "w");
    if (!f) {
        perror(filename);
        return -1;
    }

    fprintf(f, "digraph netlist {\n");
    fprintf(f, "  rankdir=LR;\n");
    fprintf(f, "  node [shape=box];\n");

    // Define color map for cores
    const char *colors[] = {
        "red", "green", "blue", "yellow", "orange",
        "purple", "brown", "pink", "gray", "cyan"
    };

    // Draw gates colored by core assignment
    for (uint32_t g = 0; g < graph->num_gates; g++) {
        uint8_t core = result->gate_to_core[g];
        const char *color = colors[core % 10];
        fprintf(f, "  g%d [label=\"G%d\\nC%d\" fillcolor=%s style=filled];\n",
                g, g, core, color);
    }

    // Draw edges (red for cross-partition)
    for (uint32_t e = 0; e < graph->num_edges; e++) {
        signal_edge_t *edge = &graph->edges[e];
        uint8_t src_core = result->gate_to_core[edge->src_gate];
        uint8_t dst_core = result->gate_to_core[edge->dst_gate];

        if (src_core != dst_core) {
            fprintf(f, "  g%d -> g%d [color=red penwidth=2];\n",
                    edge->src_gate, edge->dst_gate);
        } else {
            fprintf(f, "  g%d -> g%d;\n", edge->src_gate, edge->dst_gate);
        }
    }

    fprintf(f, "}\n");
    fclose(f);

    printf("Exported partition visualization to %s\n", filename);
    return 0;
}