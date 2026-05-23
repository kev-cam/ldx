/* test_simple.c — Simple test to debug partitioning algorithms */

#include <stdio.h>
#include <stdlib.h>
#include "rtl_partition.h"

int main(void) {
    printf("Simple partitioning test\n");

    // Create a small test netlist
    gate_desc_t gates[10];
    for (int i = 0; i < 10; i++) {
        gates[i].type = GATE_AND;
        gates[i].num_inputs = 2;
        gates[i].output_idx = i + 100;
        gates[i].input_idx[0] = i;
        gates[i].input_idx[1] = i + 50;
    }

    netlist_graph_t graph;
    printf("Building connectivity graph...\n");
    if (build_connectivity_graph(gates, 10, &graph) < 0) {
        fprintf(stderr, "Failed to build graph\n");
        return 1;
    }

    partition_result_t result;
    printf("Partitioning...\n");
    if (rtl_partition_netlist(&graph, PARTITION_ROUND_ROBIN, 4, &result) < 0) {
        fprintf(stderr, "Partitioning failed\n");
        return 1;
    }

    print_partition_stats(&result, 4);

    free(graph.edges);
    free(result.gate_to_core);
    free(result.core_gate_count);

    printf("Test completed successfully\n");
    return 0;
}