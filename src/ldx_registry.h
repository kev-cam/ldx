#ifndef LDX_REGISTRY_H
#define LDX_REGISTRY_H

/*
 * ldx_registry.h — Container registry and topology tracker.
 *
 * Tracks running containers (shards), which functions each owns,
 * and the pipe connections between them.
 *
 * Terminology:
 *   Shard     — a container running a subset of an application's functions
 *   Node      — a hardware host that runs one or more shards
 *   Route     — a pipe connection from one shard to another (for function calls)
 *               or from a shard to the OS server (for syscalls)
 *   Topology  — the graph of all shards and routes
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stddef.h>

/* Limits. */
#define LDX_MAX_SHARDS    256
#define LDX_MAX_NODES     64
#define LDX_MAX_FUNCTIONS 1024
#define LDX_MAX_ROUTES    2048

/* Shard state. */
#define LDX_SHARD_STOPPED     0
#define LDX_SHARD_RUNNING     1
#define LDX_SHARD_SUSPENDED   2
#define LDX_SHARD_MIGRATING   3

/* Route type. */
#define LDX_ROUTE_SYSCALL  0   /* shard → OS server (syscall pipe) */
#define LDX_ROUTE_FUNCTION 1   /* shard → shard (function call pipe) */

/* ---------- Data structures ---------- */

typedef struct {
    int         id;
    char        name[64];
    char        host[256];       /* hostname or IP */
    int         port;            /* SSH or management port */
    int         n_shards;        /* number of shards currently on this node */
    /* Hardware info (for placement decisions). */
    int         n_cores;
    uint64_t    memory_mb;
    char        arch[32];        /* "x86_64", "arm64", "fpga", "spinnaker" */
} ldx_node_t;

typedef struct {
    int         id;
    char        name[64];        /* e.g. "shard-0", "mysql-query", "video-decode" */
    int         node_id;         /* which node it's running on (-1 = not placed) */
    int         state;
    char        host[256];       /* actual host (from node, or overridden) */
    int         control_port;    /* control socket port */
    int         pipe_port;       /* pipe-os server port (0 = uses route) */
    int         pid;             /* PID on the node */
    /* Functions this shard owns. */
    int         func_ids[LDX_MAX_FUNCTIONS];
    int         n_funcs;
} ldx_shard_t;

typedef struct {
    int         id;
    char        name[128];       /* e.g. "libm.so:sin", "myapp:process_query" */
    int         owner_shard_id;  /* which shard owns (executes) this function */
} ldx_function_t;

typedef struct {
    int         id;
    int         from_shard_id;   /* caller */
    int         to_shard_id;     /* callee (or -1 for OS server) */
    int         route_type;      /* LDX_ROUTE_SYSCALL or LDX_ROUTE_FUNCTION */
    char        to_host[256];    /* resolved destination host */
    int         to_port;         /* resolved destination port */
    int         active;          /* 1 = connected, 0 = disconnected */
    /* Stats. */
    uint64_t    call_count;
    double      total_latency_ms;
} ldx_route_t;

/* Full topology snapshot. */
typedef struct {
    ldx_node_t      nodes[LDX_MAX_NODES];
    int             n_nodes;
    ldx_shard_t     shards[LDX_MAX_SHARDS];
    int             n_shards;
    ldx_function_t  functions[LDX_MAX_FUNCTIONS];
    int             n_functions;
    ldx_route_t     routes[LDX_MAX_ROUTES];
    int             n_routes;
} ldx_topology_t;

/* ---------- Registry API ---------- */

/* Initialize the registry. */
void ldx_registry_init(ldx_topology_t *topo);

/* Node management. */
int ldx_registry_add_node(ldx_topology_t *topo, const char *name,
                          const char *host, int port,
                          int n_cores, uint64_t memory_mb, const char *arch);
ldx_node_t *ldx_registry_get_node(ldx_topology_t *topo, int node_id);
ldx_node_t *ldx_registry_find_node(ldx_topology_t *topo, const char *name);

/* Shard management. */
int ldx_registry_add_shard(ldx_topology_t *topo, const char *name);
ldx_shard_t *ldx_registry_get_shard(ldx_topology_t *topo, int shard_id);
ldx_shard_t *ldx_registry_find_shard(ldx_topology_t *topo, const char *name);
int ldx_registry_place_shard(ldx_topology_t *topo, int shard_id, int node_id);
int ldx_registry_set_shard_state(ldx_topology_t *topo, int shard_id, int state);

/* Function ownership. */
int ldx_registry_add_function(ldx_topology_t *topo, const char *name, int owner_shard_id);
ldx_function_t *ldx_registry_find_function(ldx_topology_t *topo, const char *name);
int ldx_registry_move_function(ldx_topology_t *topo, int func_id, int new_shard_id);

/* Route management. */
int ldx_registry_add_route(ldx_topology_t *topo, int from_shard, int to_shard,
                           int route_type, const char *host, int port);
ldx_route_t *ldx_registry_get_route(ldx_topology_t *topo, int route_id);
int ldx_registry_resolve_routes(ldx_topology_t *topo, int shard_id);
int ldx_registry_disconnect_routes(ldx_topology_t *topo, int shard_id);
int ldx_registry_reconnect_routes(ldx_topology_t *topo, int shard_id);

/* Lookup: given a function call from shard X, find the route to the owner. */
ldx_route_t *ldx_registry_lookup_route(ldx_topology_t *topo,
                                       int from_shard_id, const char *func_name);

/* Migration. */
int ldx_registry_migrate_shard(ldx_topology_t *topo, int shard_id, int new_node_id);

/* Serialization (JSON). */
int ldx_registry_to_json(const ldx_topology_t *topo, char *buf, size_t buf_size);
int ldx_registry_from_json(ldx_topology_t *topo, const char *json);

/* Dump topology to stderr (human-readable). */
void ldx_registry_dump(const ldx_topology_t *topo);

#ifdef __cplusplus
}
#endif

#endif /* LDX_REGISTRY_H */
