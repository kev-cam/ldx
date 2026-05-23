/* rtl_sim_engine.h — Lock-stepped parallel RTL simulation engine.
 *
 * Architecture:
 *   - 25 cores in 5×5 mesh, each evaluates a netlist partition
 *   - Double-buffered memory: bank A (read) and bank B (write) per cycle
 *   - Synchronous evaluate/propagate cycles: all cores advance together
 *   - Cross-partition signals routed via mesh network
 *   - No AXI round-trips during steady-state simulation
 *
 * Memory layout (per core):
 *   Bank A: 0x80000000 - 0x800007FF (2 KB state vectors)
 *   Bank B: 0x80000800 - 0x80000FFF (2 KB state vectors)
 *   Gates:  0x80001000 - 0x80001FFF (4 KB gate descriptors)
 *
 * Simulation protocol:
 *   1. Load netlist partitions into all cores
 *   2. Initialize state vectors in bank A
 *   3. Loop: evaluate gates (A→B), propagate signals, swap banks
 *   4. Extract final state from current active bank
 */

#ifndef RTL_SIM_ENGINE_H
#define RTL_SIM_ENGINE_H

#include <stdint.h>

// RTL gate types
typedef enum {
    GATE_AND   = 0,
    GATE_OR    = 1,
    GATE_XOR   = 2,
    GATE_NOT   = 3,
    GATE_BUF   = 4,
    GATE_DFF   = 5,   // D flip-flop (clocked)
    GATE_REMOTE = 6   // Cross-partition signal
} gate_type_t;

// Gate descriptor (16 bytes, packed)
typedef struct {
    uint8_t  type;        // gate_type_t
    uint8_t  num_inputs;  // 1-4 inputs
    uint16_t output_idx;  // Index into state vector for output
    uint32_t input_idx[3]; // Indices for inputs (packed)
} gate_desc_t;

// Remote signal descriptor (cross-partition)
typedef struct {
    uint16_t target_core; // Core ID (0-24)
    uint16_t target_idx;  // State index on target core
    uint8_t  mesh_dir;    // Direction to route (0=N,1=E,2=S,3=W)
    uint8_t  _reserved[3];
} remote_desc_t;

// Partition descriptor
typedef struct {
    uint32_t num_gates;     // Number of gates in this partition
    uint32_t num_states;    // Size of state vector
    uint32_t num_remotes;   // Number of cross-partition signals
    uint32_t cycle_count;   // Current simulation cycle
    uint32_t bank_select;   // 0=A active, 1=B active
} partition_desc_t;

// Memory layout constants
#define BANK_A_BASE   0x80000000
#define BANK_B_BASE   0x80000800
#define GATE_BASE     0x80001000
#define REMOTE_BASE   0x80001800
#define PARTITION_BASE 0x80001C00
#define STATE_SIZE    0x800    // 2 KB per bank
#define MAX_GATES     256      // 4 KB / 16 bytes per gate
#define MAX_REMOTES   128      // Cross-partition signals

// Mesh communication protocol
#define MSG_TYPE_SIGNAL  0x01   // Signal propagation
#define MSG_TYPE_SYNC    0x02   // Synchronization barrier
#define MSG_TYPE_DONE    0x03   // Simulation complete

typedef struct {
    uint32_t type;      // Message type
    uint32_t data;      // Signal value or sync token
} mesh_msg_t;

// Core management
typedef struct {
    uint8_t my_x, my_y;     // Mesh coordinates
    uint8_t core_id;        // Linear ID (x*5 + y)
    uint8_t active_bank;    // Current active bank (0=A, 1=B)
    uint32_t cycle;         // Current cycle number
    uint32_t barrier_token; // Sync barrier token
} core_state_t;

// Function prototypes
void rtl_sim_init(void);
void rtl_sim_load_partition(const gate_desc_t *gates, uint32_t num_gates,
                           const remote_desc_t *remotes, uint32_t num_remotes,
                           const uint8_t *init_state, uint32_t state_size);
void rtl_sim_step(void);
void rtl_sim_run(uint32_t max_cycles);
uint8_t *rtl_sim_get_state(void);

// Internal functions
void evaluate_gates(void);
void propagate_signals(void);
void sync_barrier(void);
void swap_banks(void);

// Mesh communication helpers
void mesh_send(uint8_t dir, const mesh_msg_t *msg);
int mesh_recv(uint8_t dir, mesh_msg_t *msg); // 0=no msg, 1=msg received
void route_signal(uint16_t target_core, uint16_t target_idx, uint8_t value);

#endif /* RTL_SIM_ENGINE_H */