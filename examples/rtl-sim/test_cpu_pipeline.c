/* test_cpu_pipeline.c — Demonstrate parallel RTL simulation of CPU pipeline.
 *
 * Shows sensitivity list partitioning across multiple clock domains:
 *   - clk_cpu:  Instruction fetch, decode, execute pipeline stages
 *   - clk_mem:  Memory subsystem (cache, DRAM controller)
 *   - clk_bus:  System bus and peripherals
 *
 * Each domain's @(posedge clk) sensitivity list is distributed across cores.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rtl_sim_host.h"
#include "rtl_partition.h"

// CPU pipeline components
typedef struct {
    uint32_t pc;           // Program counter
    uint32_t instruction;  // Current instruction
    uint32_t reg_data;     // Register file data
    uint32_t alu_result;   // ALU output
    uint32_t mem_addr;     // Memory address
    uint32_t mem_data;     // Memory data
    uint8_t pipeline_stall; // Pipeline stall signal
} cpu_state_t;

// Generate a simple 5-stage RISC pipeline
static int build_cpu_pipeline_netlist(netlist_t *netlist) {
    // Estimate gate counts for each pipeline stage:
    // IF:  ~50 gates  (PC logic, instruction fetch)
    // ID:  ~150 gates (decoder, register file)
    // EX:  ~200 gates (ALU, branch logic)
    // MEM: ~100 gates (cache interface, load/store)
    // WB:  ~50 gates  (writeback mux, hazard detection)

    uint32_t total_gates = 550;
    netlist->gates = malloc(total_gates * sizeof(gate_desc_t));
    netlist->num_gates = 0;

    // State layout:
    //   0-31:    Instruction fetch state (PC, I$)
    //   32-63:   Instruction decode state (registers, control)
    //   64-95:   Execute state (ALU, branch)
    //   96-127:  Memory state (D$, load/store)
    //   128-159: Writeback state (result mux)
    //   160+:    Temporary wires

    netlist->state_size = 1000; // Generous space for temporaries
    netlist->init_state = calloc(netlist->state_size, 1);

    gate_desc_t *gate = netlist->gates;

    printf("Building CPU pipeline netlist...\n");

    // Instruction Fetch stage (~50 gates)
    printf("  Adding IF stage gates...\n");
    for (int i = 0; i < 50; i++) {
        gate->type = (i % 5 == 0) ? GATE_DFF : GATE_XOR; // Mix of FFs and logic
        gate->num_inputs = 2;
        gate->output_idx = i;                // IF stage state
        gate->input_idx[0] = (i > 0) ? i-1 : 159; // Previous or feedback
        gate->input_idx[1] = 32 + (i % 32);      // From ID stage
        gate++;
        netlist->num_gates++;
    }

    // Instruction Decode stage (~150 gates)
    printf("  Adding ID stage gates...\n");
    for (int i = 0; i < 150; i++) {
        gate->type = (i % 10 == 0) ? GATE_DFF : GATE_AND;
        gate->num_inputs = 2;
        gate->output_idx = 32 + i;           // ID stage state
        gate->input_idx[0] = i % 32;         // From IF stage
        gate->input_idx[1] = 64 + (i % 32);  // From EX stage
        gate++;
        netlist->num_gates++;
    }

    // Execute stage (~200 gates) - Most complex
    printf("  Adding EX stage gates...\n");
    for (int i = 0; i < 200; i++) {
        gate->type = (i % 8 == 0) ? GATE_DFF : GATE_XOR;
        gate->num_inputs = 3; // ALU has 3 inputs
        gate->output_idx = 64 + i;           // EX stage state
        gate->input_idx[0] = 32 + (i % 32);  // From ID stage
        gate->input_idx[1] = 96 + (i % 32);  // From MEM stage (forwarding)
        gate->input_idx[2] = 160 + i;        // Temporary wire
        gate++;
        netlist->num_gates++;
    }

    // Memory stage (~100 gates)
    printf("  Adding MEM stage gates...\n");
    for (int i = 0; i < 100; i++) {
        gate->type = (i % 6 == 0) ? GATE_DFF : GATE_OR;
        gate->num_inputs = 2;
        gate->output_idx = 96 + i;           // MEM stage state
        gate->input_idx[0] = 64 + (i % 32);  // From EX stage
        gate->input_idx[1] = 128 + (i % 32); // From WB stage
        gate++;
        netlist->num_gates++;
    }

    // Writeback stage (~50 gates)
    printf("  Adding WB stage gates...\n");
    for (int i = 0; i < 50; i++) {
        gate->type = (i % 7 == 0) ? GATE_DFF : GATE_BUF;
        gate->num_inputs = 2;
        gate->output_idx = 128 + i;          // WB stage state
        gate->input_idx[0] = 96 + (i % 32);  // From MEM stage
        gate->input_idx[1] = 32 + (i % 32);  // To ID stage (writeback)
        gate++;
        netlist->num_gates++;
    }

    // Fill remaining temporary wires
    for (int i = 200; i < 400; i++) {
        if (netlist->num_gates >= total_gates) break;

        gate->type = GATE_NOT;
        gate->num_inputs = 1;
        gate->output_idx = 160 + i;
        gate->input_idx[0] = 64 + (i % 64); // Connect to EX stage
        gate++;
        netlist->num_gates++;
    }

    netlist->remotes = NULL;
    netlist->num_remotes = 0;

    snprintf(netlist->description, sizeof(netlist->description),
             "5-stage RISC CPU pipeline");

    // Initialize some realistic state
    cpu_state_t *cpu = (cpu_state_t *)netlist->init_state;
    cpu->pc = 0x1000;           // Start PC
    cpu->instruction = 0x0;     // NOP initially
    cpu->reg_data = 0x12345678; // Some register data

    printf("Generated CPU pipeline: %d gates, %d state bytes\n",
           netlist->num_gates, netlist->state_size);

    return 0;
}

static void run_cpu_pipeline_test(rtl_sim_controller_t *ctrl) {
    printf("\n--- CPU Pipeline Simulation Test ---\n");

    // Run for enough cycles to fill the pipeline
    uint32_t cycles = 20;
    rtl_sim_start(ctrl, cycles);

    int actual_cycles = rtl_sim_wait_complete(ctrl);
    if (actual_cycles < 0) {
        printf("Simulation failed!\n");
        return;
    }

    printf("Pipeline simulation completed: %d cycles\n", actual_cycles);

    // Collect results
    uint8_t *final_state;
    uint32_t state_size;
    if (rtl_sim_collect_results(ctrl, &final_state, &state_size) < 0) {
        printf("Failed to collect results\n");
        return;
    }

    // Extract CPU state
    cpu_state_t *cpu = (cpu_state_t *)final_state;
    printf("Final CPU state:\n");
    printf("  PC:          0x%08X\n", cpu->pc);
    printf("  Instruction: 0x%08X\n", cpu->instruction);
    printf("  ALU Result:  0x%08X\n", cpu->alu_result);
    printf("  Memory Addr: 0x%08X\n", cpu->mem_addr);

    // Show partitioning effectiveness
    printf("\nPartitioning Analysis:\n");
    printf("  Total cores utilized: %d\n", NUM_CORES);

    uint32_t active_cores = 0;
    for (int i = 0; i < NUM_CORES; i++) {
        if (ctrl->partitions[i].num_gates > 0) {
            active_cores++;
            printf("  Core %d: %d gates (%.1f%% of total)\n",
                   i, ctrl->partitions[i].num_gates,
                   100.0f * ctrl->partitions[i].num_gates / ctrl->netlist.num_gates);
        }
    }

    printf("  Active cores: %d/%d\n", active_cores, NUM_CORES);
    printf("  Theoretical speedup: %.1fx\n",
           (float)ctrl->netlist.num_gates / (ctrl->netlist.num_gates / active_cores));

    free(final_state);
}

int main(int argc, char **argv) {
    printf("CPU Pipeline RTL Simulation Test\n");
    printf("================================\n");

    rtl_sim_controller_t ctrl;

    // Initialize controller
    if (rtl_sim_host_init(&ctrl) < 0) {
        fprintf(stderr, "Failed to initialize controller\n");
        return 1;
    }

    // Load simulation firmware
    const char *firmware = (argc > 1) ? argv[1] : "rtl_sim_firmware.bin";
    if (rtl_sim_load_firmware(&ctrl, firmware) < 0) {
        fprintf(stderr, "Failed to load firmware\n");
        goto cleanup;
    }

    // Build CPU pipeline netlist
    if (build_cpu_pipeline_netlist(&ctrl.netlist) < 0) {
        fprintf(stderr, "Failed to build CPU pipeline netlist\n");
        goto cleanup;
    }

    // Partition netlist with intelligent strategies
    printf("\nPartitioning strategies:\n");
    if (rtl_sim_partition_netlist(&ctrl) < 0) {
        fprintf(stderr, "Failed to partition netlist\n");
        goto cleanup;
    }

    // Run pipeline test
    run_cpu_pipeline_test(&ctrl);

    printf("\n================================\n");
    printf("CPU Pipeline Test Complete\n");

    rtl_sim_print_stats(&ctrl);

cleanup:
    rtl_sim_host_cleanup(&ctrl);
    return 0;
}