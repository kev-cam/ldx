/* nvc_3d_accel.h — 3D Logic Acceleration for NVC VHDL Simulator
 *
 * Extends our 2D mesh RTL simulation to 3D cube topologies for VHDL.
 * VHDL's hierarchical nature maps naturally to 3D spatial partitioning:
 *
 * - X-axis: Sequential processes within an entity
 * - Y-axis: Concurrent processes across entities
 * - Z-axis: Hierarchical entity instantiations
 *
 * This creates a true 3D logic fabric where VHDL processes execute
 * in spatially-organized cores with dedicated interconnect.
 */

#ifndef NVC_3D_ACCEL_H
#define NVC_3D_ACCEL_H

#include <stdint.h>

// 3D mesh dimensions
typedef struct {
    uint8_t x, y, z;           // Coordinates in 3D mesh
    uint16_t linear_id;        // Flattened ID for addressing
} mesh_3d_coord_t;

// 3D logic acceleration modes
typedef enum {
    ACCEL_PROCESS_PARALLEL,    // Parallelize VHDL processes
    ACCEL_HIERARCHY_VERTICAL,  // Map hierarchy to Z-axis
    ACCEL_SIGNAL_SPATIAL,      // Spatial signal routing
    ACCEL_TEMPORAL_3D,         // 3D temporal decomposition
    ACCEL_MIXED_MODE          // Hybrid acceleration
} accel_mode_t;

// 3D mesh topology (N×M×P cores)
typedef struct {
    uint8_t width;             // X dimension (processes)
    uint8_t height;            // Y dimension (entities)
    uint8_t depth;             // Z dimension (hierarchy)
    uint16_t total_cores;      // width × height × depth
    accel_mode_t mode;         // Acceleration strategy
} mesh_3d_topology_t;

// VHDL process descriptor for 3D mapping
typedef struct {
    uint32_t process_id;       // NVC process identifier
    mesh_3d_coord_t location;  // 3D mesh placement
    uint16_t sensitivity_count;// Number of sensitivity list signals
    uint32_t *sensitivity_ids; // Signal IDs in sensitivity list
    uint8_t hierarchy_level;   // Entity hierarchy depth
    uint32_t parent_entity;    // Parent entity ID
    uint8_t process_type;      // Sequential/concurrent/clocked
} vhdl_process_3d_t;

// 3D signal routing
typedef struct {
    uint32_t signal_id;        // NVC signal identifier
    mesh_3d_coord_t source;    // Source process location
    mesh_3d_coord_t dest[8];   // Destination locations (max 8)
    uint8_t dest_count;        // Number of destinations
    uint8_t routing_mode;      // Direct/buffered/broadcast
} signal_route_3d_t;

// 3D mesh interconnect (6 directions: ±X, ±Y, ±Z)
typedef enum {
    DIR_EAST = 0,   // +X
    DIR_WEST = 1,   // -X
    DIR_NORTH = 2,  // +Y
    DIR_SOUTH = 3,  // -Y
    DIR_UP = 4,     // +Z (hierarchy up)
    DIR_DOWN = 5    // -Z (hierarchy down)
} mesh_3d_direction_t;

// 3D core configuration
typedef struct {
    mesh_3d_coord_t coord;            // 3D coordinates
    uint32_t num_processes;           // VHDL processes on this core
    vhdl_process_3d_t *processes;     // Process descriptors
    uint32_t memory_size_kb;          // Local memory allocation
    uint8_t acceleration_features;    // Feature flags
} core_3d_config_t;

// Main 3D acceleration context
typedef struct {
    mesh_3d_topology_t topology;     // 3D mesh configuration
    core_3d_config_t *cores;          // Per-core configurations
    signal_route_3d_t *signal_routes; // 3D signal routing table
    uint32_t total_signals;           // Number of routed signals
    uint32_t total_processes;         // Total VHDL processes
    void *nvc_runtime_context;       // NVC runtime integration
} nvc_3d_context_t;

// Function prototypes

// Initialization
int nvc_3d_init(nvc_3d_context_t *ctx, uint8_t x, uint8_t y, uint8_t z,
                accel_mode_t mode);
void nvc_3d_cleanup(nvc_3d_context_t *ctx);

// VHDL process mapping
int nvc_3d_map_process(nvc_3d_context_t *ctx, uint32_t process_id,
                       uint32_t *sensitivity_list, uint16_t sensitivity_count,
                       uint8_t hierarchy_level, uint32_t parent_entity);

// 3D signal routing
int nvc_3d_route_signal(nvc_3d_context_t *ctx, uint32_t signal_id,
                        mesh_3d_coord_t source, mesh_3d_coord_t *destinations,
                        uint8_t dest_count);

// Acceleration execution
int nvc_3d_accelerate_simulation(nvc_3d_context_t *ctx, uint64_t time_limit_fs);
int nvc_3d_step_simulation(nvc_3d_context_t *ctx);

// 3D mesh utilities
mesh_3d_coord_t linear_to_3d(uint16_t linear_id, mesh_3d_topology_t *topo);
uint16_t coord_3d_to_linear(mesh_3d_coord_t coord, mesh_3d_topology_t *topo);
mesh_3d_direction_t get_direction_3d(mesh_3d_coord_t from, mesh_3d_coord_t to);
int is_neighbor_3d(mesh_3d_coord_t a, mesh_3d_coord_t b);

// Performance monitoring
typedef struct {
    uint64_t process_executions;      // Total process runs
    uint64_t signal_propagations;     // Signal routing events
    uint64_t hierarchy_traversals;    // Z-axis movements
    uint64_t sync_cycles;            // Synchronization overhead
    float avg_core_utilization;      // Average core usage
    float communication_overhead;     // 3D routing overhead
} nvc_3d_stats_t;

void nvc_3d_get_stats(nvc_3d_context_t *ctx, nvc_3d_stats_t *stats);

// Hardware integration (ZCU104 3D mesh)
int nvc_3d_init_fpga(nvc_3d_context_t *ctx, const char *bitstream_path);
int nvc_3d_load_processes(nvc_3d_context_t *ctx);
int nvc_3d_sync_fpga(nvc_3d_context_t *ctx);

#endif /* NVC_3D_ACCEL_H */