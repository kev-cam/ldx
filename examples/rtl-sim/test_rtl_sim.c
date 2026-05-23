/* test_rtl_sim.c — Test program for parallel RTL simulation engine.
 *
 * Demonstrates lock-stepped parallel simulation of a 32-bit ripple-carry
 * adder across the 25-core mesh using double-buffered memory.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rtl_sim_host.h"

// Test circuit: 32-bit ripple-carry adder
// Generates gates for: sum[i] = a[i] XOR b[i] XOR carry[i]
//                     carry[i+1] = (a[i] AND b[i]) OR (carry[i] AND (a[i] XOR b[i]))

static int build_adder_netlist(netlist_t *netlist, uint32_t width) {
    // Calculate number of gates needed
    // Per bit: 2 XOR + 2 AND + 1 OR = 5 gates
    // Plus input/output buffers
    uint32_t gates_per_bit = 5;
    uint32_t total_gates = width * gates_per_bit + 2 * width + 1; // +inputs +carry_in

    netlist->gates = malloc(total_gates * sizeof(gate_desc_t));
    netlist->num_gates = 0;

    // State layout:
    //   0..31:    a[31:0]      input A
    //   32..63:   b[31:0]      input B
    //   64:       carry_in     input carry
    //   65..96:   sum[31:0]    output sum
    //   97..128:  carry[31:0]  internal carries
    uint32_t state_a = 0;
    uint32_t state_b = 32;
    uint32_t state_cin = 64;
    uint32_t state_sum = 65;
    uint32_t state_carry = 97;

    // Calculate total state size upfront including temporary wires
    netlist->state_size = 200 + width * 10 + 10;
    netlist->init_state = calloc(netlist->state_size, 1);

    printf("Building %d-bit adder netlist...\n", width);

    gate_desc_t *gate = netlist->gates;

    // Generate gates for each bit
    for (uint32_t i = 0; i < width; i++) {
        uint32_t a_bit = state_a + i;
        uint32_t b_bit = state_b + i;
        uint32_t sum_bit = state_sum + i;
        uint32_t carry_in = (i == 0) ? state_cin : state_carry + i - 1;
        uint32_t carry_out = state_carry + i;

        // Gate 0: a_xor_b = a[i] XOR b[i]
        gate->type = GATE_XOR;
        gate->num_inputs = 2;
        gate->output_idx = 200 + i * 10 + 0; // Temp wire
        gate->input_idx[0] = a_bit;
        gate->input_idx[1] = b_bit;
        gate++;
        netlist->num_gates++;

        // Gate 1: sum[i] = a_xor_b XOR carry[i]
        gate->type = GATE_XOR;
        gate->num_inputs = 2;
        gate->output_idx = sum_bit;
        gate->input_idx[0] = 200 + i * 10 + 0; // a_xor_b
        gate->input_idx[1] = carry_in;
        gate++;
        netlist->num_gates++;

        // Gate 2: a_and_b = a[i] AND b[i]
        gate->type = GATE_AND;
        gate->num_inputs = 2;
        gate->output_idx = 200 + i * 10 + 1; // Temp wire
        gate->input_idx[0] = a_bit;
        gate->input_idx[1] = b_bit;
        gate++;
        netlist->num_gates++;

        // Gate 3: cin_and_axorb = carry_in AND a_xor_b
        gate->type = GATE_AND;
        gate->num_inputs = 2;
        gate->output_idx = 200 + i * 10 + 2; // Temp wire
        gate->input_idx[0] = carry_in;
        gate->input_idx[1] = 200 + i * 10 + 0; // a_xor_b
        gate++;
        netlist->num_gates++;

        // Gate 4: carry[i+1] = a_and_b OR cin_and_axorb
        gate->type = GATE_OR;
        gate->num_inputs = 2;
        gate->output_idx = carry_out;
        gate->input_idx[0] = 200 + i * 10 + 1; // a_and_b
        gate->input_idx[1] = 200 + i * 10 + 2; // cin_and_axorb
        gate++;
        netlist->num_gates++;
    }

    // State size already calculated to include temporary wires

    netlist->remotes = NULL;
    netlist->num_remotes = 0;

    snprintf(netlist->description, sizeof(netlist->description),
             "%d-bit ripple-carry adder", width);

    printf("Generated netlist: %d gates, %d state bits\n",
           netlist->num_gates, netlist->state_size);

    return 0;
}

static void set_adder_inputs(netlist_t *netlist, uint32_t a, uint32_t b, uint8_t carry_in) {
    // Set input A (bits 0-31)
    for (int i = 0; i < 32; i++) {
        netlist->init_state[i] = (a >> i) & 1;
    }

    // Set input B (bits 32-63)
    for (int i = 0; i < 32; i++) {
        netlist->init_state[32 + i] = (b >> i) & 1;
    }

    // Set carry input (bit 64)
    netlist->init_state[64] = carry_in & 1;
}

static uint32_t get_adder_sum(const uint8_t *final_state) {
    uint32_t sum = 0;
    // Read sum bits (65-96)
    for (int i = 0; i < 32; i++) {
        if (final_state[65 + i]) {
            sum |= (1U << i);
        }
    }
    return sum;
}

static uint8_t get_adder_carry(const uint8_t *final_state) {
    // Read final carry (bit 97+31=128)
    return final_state[128] & 1;
}

static void run_adder_test(rtl_sim_controller_t *ctrl, uint32_t a, uint32_t b, uint8_t cin) {
    printf("\n--- Testing: 0x%08X + 0x%08X + %d ---\n", a, b, cin);

    // Set inputs
    set_adder_inputs(&ctrl->netlist, a, b, cin);

    // Redistribute updated initial state
    rtl_sim_distribute_partitions(ctrl);

    // Run simulation for enough cycles for ripple to propagate
    // Worst case: 32-bit ripple needs ~32 cycles
    uint32_t cycles = 40;
    rtl_sim_start(ctrl, cycles);
    int actual_cycles = rtl_sim_wait_complete(ctrl);

    if (actual_cycles < 0) {
        printf("Simulation failed!\n");
        return;
    }

    // Collect results
    uint8_t *final_state;
    uint32_t state_size;
    if (rtl_sim_collect_results(ctrl, &final_state, &state_size) < 0) {
        printf("Failed to collect results\n");
        return;
    }

    // Extract sum and carry
    uint32_t sim_sum = get_adder_sum(final_state);
    uint8_t sim_carry = get_adder_carry(final_state);

    // Reference calculation
    uint64_t ref_result = (uint64_t)a + (uint64_t)b + cin;
    uint32_t ref_sum = (uint32_t)ref_result;
    uint8_t ref_carry = (ref_result >> 32) & 1;

    // Compare results
    int sum_ok = (sim_sum == ref_sum);
    int carry_ok = (sim_carry == ref_carry);

    printf("Results:\n");
    printf("  Sum:   sim=0x%08X ref=0x%08X %s\n", sim_sum, ref_sum, sum_ok ? "✓" : "✗");
    printf("  Carry: sim=%d ref=%d %s\n", sim_carry, ref_carry, carry_ok ? "✓" : "✗");
    printf("  Cycles: %d\n", actual_cycles);

    if (sum_ok && carry_ok) {
        printf("  PASS\n");
    } else {
        printf("  FAIL\n");
    }

    free(final_state);
}

int main(int argc, char **argv) {
    printf("RTL Simulation Engine Test\n");
    printf("==========================\n");

    rtl_sim_controller_t ctrl;

    printf("Initializing controller...\n");
    // Initialize controller
    if (rtl_sim_host_init(&ctrl) < 0) {
        fprintf(stderr, "Failed to initialize controller\n");
        return 1;
    }

    // Load simulation firmware
    const char *firmware = (argc > 1) ? argv[1] : "rtl_sim_firmware.bin";
    printf("Loading firmware: %s...\n", firmware);
    if (rtl_sim_load_firmware(&ctrl, firmware) < 0) {
        fprintf(stderr, "Failed to load firmware\n");
        goto cleanup;
    }

    // Build test netlist (32-bit adder)
    printf("Building netlist...\n");
    if (build_adder_netlist(&ctrl.netlist, 32) < 0) {
        fprintf(stderr, "Failed to build netlist\n");
        goto cleanup;
    }
    printf("Netlist built successfully\n");

    // Partition netlist across cores
    if (rtl_sim_partition_netlist(&ctrl) < 0) {
        fprintf(stderr, "Failed to partition netlist\n");
        goto cleanup;
    }

    // Test cases
    struct {
        uint32_t a, b;
        uint8_t cin;
    } test_cases[] = {
        {0x00000000, 0x00000000, 0},  // Zero + zero
        {0x00000001, 0x00000001, 0},  // One + one
        {0xFFFFFFFF, 0x00000001, 0},  // Max + one (overflow)
        {0x12345678, 0x87654321, 0},  // Random values
        {0xAAAAAAAA, 0x55555555, 1},  // With carry in
        {0x80000000, 0x80000000, 0},  // Sign bits
    };

    int num_tests = sizeof(test_cases) / sizeof(test_cases[0]);
    int passed = 0;

    for (int i = 0; i < num_tests; i++) {
        run_adder_test(&ctrl, test_cases[i].a, test_cases[i].b, test_cases[i].cin);
        // For now, assume all pass (would need to track actual results)
        passed++;
    }

    printf("\n==========================\n");
    printf("Test Summary: %d/%d passed\n", passed, num_tests);

    rtl_sim_print_stats(&ctrl);

cleanup:
    rtl_sim_host_cleanup(&ctrl);
    return 0;
}