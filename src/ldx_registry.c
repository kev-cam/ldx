#define _GNU_SOURCE
#include "ldx_registry.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------- init ---------- */

void ldx_registry_init(ldx_topology_t *topo)
{
    memset(topo, 0, sizeof(*topo));
}

/* ---------- nodes ---------- */

int ldx_registry_add_node(ldx_topology_t *topo, const char *name,
                          const char *host, int port,
                          int n_cores, uint64_t memory_mb, const char *arch)
{
    if (topo->n_nodes >= LDX_MAX_NODES) return -1;
    int id = topo->n_nodes;
    ldx_node_t *n = &topo->nodes[id];
    n->id = id;
    snprintf(n->name, sizeof(n->name), "%s", name);
    snprintf(n->host, sizeof(n->host), "%s", host);
    n->port = port;
    n->n_cores = n_cores;
    n->memory_mb = memory_mb;
    snprintf(n->arch, sizeof(n->arch), "%s", arch ? arch : "x86_64");
    n->n_shards = 0;
    topo->n_nodes++;
    return id;
}

ldx_node_t *ldx_registry_get_node(ldx_topology_t *topo, int node_id)
{
    if (node_id < 0 || node_id >= topo->n_nodes) return NULL;
    return &topo->nodes[node_id];
}

ldx_node_t *ldx_registry_find_node(ldx_topology_t *topo, const char *name)
{
    for (int i = 0; i < topo->n_nodes; i++)
        if (strcmp(topo->nodes[i].name, name) == 0)
            return &topo->nodes[i];
    return NULL;
}

/* ---------- shards ---------- */

int ldx_registry_add_shard(ldx_topology_t *topo, const char *name)
{
    if (topo->n_shards >= LDX_MAX_SHARDS) return -1;
    int id = topo->n_shards;
    ldx_shard_t *s = &topo->shards[id];
    memset(s, 0, sizeof(*s));
    s->id = id;
    s->node_id = -1;
    s->state = LDX_SHARD_STOPPED;
    snprintf(s->name, sizeof(s->name), "%s", name);
    topo->n_shards++;
    return id;
}

ldx_shard_t *ldx_registry_get_shard(ldx_topology_t *topo, int shard_id)
{
    if (shard_id < 0 || shard_id >= topo->n_shards) return NULL;
    return &topo->shards[shard_id];
}

ldx_shard_t *ldx_registry_find_shard(ldx_topology_t *topo, const char *name)
{
    for (int i = 0; i < topo->n_shards; i++)
        if (strcmp(topo->shards[i].name, name) == 0)
            return &topo->shards[i];
    return NULL;
}

int ldx_registry_place_shard(ldx_topology_t *topo, int shard_id, int node_id)
{
    ldx_shard_t *s = ldx_registry_get_shard(topo, shard_id);
    ldx_node_t *n = ldx_registry_get_node(topo, node_id);
    if (!s || !n) return -1;

    /* Remove from old node. */
    if (s->node_id >= 0) {
        ldx_node_t *old = ldx_registry_get_node(topo, s->node_id);
        if (old) old->n_shards--;
    }

    s->node_id = node_id;
    snprintf(s->host, sizeof(s->host), "%s", n->host);
    n->n_shards++;
    return 0;
}

int ldx_registry_set_shard_state(ldx_topology_t *topo, int shard_id, int state)
{
    ldx_shard_t *s = ldx_registry_get_shard(topo, shard_id);
    if (!s) return -1;
    s->state = state;
    return 0;
}

/* ---------- functions ---------- */

int ldx_registry_add_function(ldx_topology_t *topo, const char *name, int owner_shard_id)
{
    if (topo->n_functions >= LDX_MAX_FUNCTIONS) return -1;
    int id = topo->n_functions;
    ldx_function_t *f = &topo->functions[id];
    f->id = id;
    snprintf(f->name, sizeof(f->name), "%s", name);
    f->owner_shard_id = owner_shard_id;

    /* Add to shard's function list. */
    ldx_shard_t *s = ldx_registry_get_shard(topo, owner_shard_id);
    if (s && s->n_funcs < LDX_MAX_FUNCTIONS)
        s->func_ids[s->n_funcs++] = id;

    topo->n_functions++;
    return id;
}

ldx_function_t *ldx_registry_find_function(ldx_topology_t *topo, const char *name)
{
    for (int i = 0; i < topo->n_functions; i++)
        if (strcmp(topo->functions[i].name, name) == 0)
            return &topo->functions[i];
    return NULL;
}

int ldx_registry_move_function(ldx_topology_t *topo, int func_id, int new_shard_id)
{
    if (func_id < 0 || func_id >= topo->n_functions) return -1;
    ldx_function_t *f = &topo->functions[func_id];

    /* Remove from old shard's list. */
    ldx_shard_t *old = ldx_registry_get_shard(topo, f->owner_shard_id);
    if (old) {
        for (int i = 0; i < old->n_funcs; i++) {
            if (old->func_ids[i] == func_id) {
                old->func_ids[i] = old->func_ids[--old->n_funcs];
                break;
            }
        }
    }

    f->owner_shard_id = new_shard_id;

    /* Add to new shard's list. */
    ldx_shard_t *ns = ldx_registry_get_shard(topo, new_shard_id);
    if (ns && ns->n_funcs < LDX_MAX_FUNCTIONS)
        ns->func_ids[ns->n_funcs++] = func_id;

    return 0;
}

/* ---------- routes ---------- */

int ldx_registry_add_route(ldx_topology_t *topo, int from_shard, int to_shard,
                           int route_type, const char *host, int port)
{
    if (topo->n_routes >= LDX_MAX_ROUTES) return -1;
    int id = topo->n_routes;
    ldx_route_t *r = &topo->routes[id];
    memset(r, 0, sizeof(*r));
    r->id = id;
    r->from_shard_id = from_shard;
    r->to_shard_id = to_shard;
    r->route_type = route_type;
    if (host)
        snprintf(r->to_host, sizeof(r->to_host), "%s", host);
    r->to_port = port;
    r->active = 0;
    topo->n_routes++;
    return id;
}

ldx_route_t *ldx_registry_get_route(ldx_topology_t *topo, int route_id)
{
    if (route_id < 0 || route_id >= topo->n_routes) return NULL;
    return &topo->routes[route_id];
}

/* Resolve route destinations from shard placement. */
int ldx_registry_resolve_routes(ldx_topology_t *topo, int shard_id)
{
    int resolved = 0;
    for (int i = 0; i < topo->n_routes; i++) {
        ldx_route_t *r = &topo->routes[i];
        if (r->from_shard_id != shard_id) continue;

        if (r->to_shard_id >= 0) {
            /* Route to another shard — resolve its host:port. */
            ldx_shard_t *dest = ldx_registry_get_shard(topo, r->to_shard_id);
            if (dest && dest->host[0]) {
                snprintf(r->to_host, sizeof(r->to_host), "%s", dest->host);
                r->to_port = dest->pipe_port;
                resolved++;
            }
        }
        /* Syscall routes keep their explicit host:port. */
    }
    return resolved;
}

int ldx_registry_disconnect_routes(ldx_topology_t *topo, int shard_id)
{
    int count = 0;
    for (int i = 0; i < topo->n_routes; i++) {
        ldx_route_t *r = &topo->routes[i];
        if (r->from_shard_id == shard_id || r->to_shard_id == shard_id) {
            r->active = 0;
            count++;
        }
    }
    return count;
}

int ldx_registry_reconnect_routes(ldx_topology_t *topo, int shard_id)
{
    int count = 0;
    for (int i = 0; i < topo->n_routes; i++) {
        ldx_route_t *r = &topo->routes[i];
        if (r->from_shard_id == shard_id && r->to_host[0] && r->to_port > 0) {
            r->active = 1;
            count++;
        }
    }
    return count;
}

ldx_route_t *ldx_registry_lookup_route(ldx_topology_t *topo,
                                       int from_shard_id, const char *func_name)
{
    /* Find which shard owns the function. */
    ldx_function_t *f = ldx_registry_find_function(topo, func_name);
    if (!f) return NULL;

    /* Find route from caller to owner. */
    for (int i = 0; i < topo->n_routes; i++) {
        ldx_route_t *r = &topo->routes[i];
        if (r->from_shard_id == from_shard_id &&
            r->to_shard_id == f->owner_shard_id &&
            r->route_type == LDX_ROUTE_FUNCTION)
            return r;
    }
    return NULL;
}

/* ---------- migration ---------- */

int ldx_registry_migrate_shard(ldx_topology_t *topo, int shard_id, int new_node_id)
{
    ldx_shard_t *s = ldx_registry_get_shard(topo, shard_id);
    if (!s) return -1;

    /* 1. Mark as migrating. */
    s->state = LDX_SHARD_MIGRATING;

    /* 2. Disconnect all routes. */
    ldx_registry_disconnect_routes(topo, shard_id);

    /* 3. Place on new node. */
    ldx_registry_place_shard(topo, shard_id, new_node_id);

    /* 4. Resolve routes with new placement. */
    ldx_registry_resolve_routes(topo, shard_id);

    /* Also resolve routes FROM other shards TO this one. */
    for (int i = 0; i < topo->n_routes; i++) {
        if (topo->routes[i].to_shard_id == shard_id) {
            snprintf(topo->routes[i].to_host, sizeof(topo->routes[i].to_host),
                     "%s", s->host);
        }
    }

    return 0;
}

/* ---------- JSON serialization ---------- */

int ldx_registry_to_json(const ldx_topology_t *topo, char *buf, size_t buf_size)
{
    int off = 0;
    int rem = (int)buf_size;

#define APPEND(...) do { \
    int _w = snprintf(buf + off, rem, __VA_ARGS__); \
    if (_w > 0) { off += _w; rem -= _w; } \
} while(0)

    APPEND("{");

    /* Nodes. */
    APPEND("\"nodes\":[");
    for (int i = 0; i < topo->n_nodes; i++) {
        const ldx_node_t *n = &topo->nodes[i];
        if (i) APPEND(",");
        APPEND("{\"id\":%d,\"name\":\"%s\",\"host\":\"%s\",\"port\":%d,"
               "\"cores\":%d,\"memory_mb\":%lu,\"arch\":\"%s\",\"shards\":%d}",
               n->id, n->name, n->host, n->port,
               n->n_cores, (unsigned long)n->memory_mb, n->arch, n->n_shards);
    }
    APPEND("],");

    /* Shards. */
    APPEND("\"shards\":[");
    for (int i = 0; i < topo->n_shards; i++) {
        const ldx_shard_t *s = &topo->shards[i];
        const char *state_str;
        switch (s->state) {
        case LDX_SHARD_RUNNING:   state_str = "running"; break;
        case LDX_SHARD_SUSPENDED: state_str = "suspended"; break;
        case LDX_SHARD_MIGRATING: state_str = "migrating"; break;
        default:                  state_str = "stopped"; break;
        }
        if (i) APPEND(",");
        APPEND("{\"id\":%d,\"name\":\"%s\",\"node_id\":%d,\"state\":\"%s\","
               "\"host\":\"%s\",\"control_port\":%d,\"pipe_port\":%d,"
               "\"n_funcs\":%d}",
               s->id, s->name, s->node_id, state_str,
               s->host, s->control_port, s->pipe_port, s->n_funcs);
    }
    APPEND("],");

    /* Functions. */
    APPEND("\"functions\":[");
    for (int i = 0; i < topo->n_functions; i++) {
        const ldx_function_t *f = &topo->functions[i];
        if (i) APPEND(",");
        APPEND("{\"id\":%d,\"name\":\"%s\",\"owner\":%d}",
               f->id, f->name, f->owner_shard_id);
    }
    APPEND("],");

    /* Routes. */
    APPEND("\"routes\":[");
    for (int i = 0; i < topo->n_routes; i++) {
        const ldx_route_t *r = &topo->routes[i];
        if (i) APPEND(",");
        APPEND("{\"id\":%d,\"from\":%d,\"to\":%d,\"type\":\"%s\","
               "\"host\":\"%s\",\"port\":%d,\"active\":%s,"
               "\"calls\":%lu,\"latency_ms\":%.3f}",
               r->id, r->from_shard_id, r->to_shard_id,
               r->route_type == LDX_ROUTE_SYSCALL ? "syscall" : "function",
               r->to_host, r->to_port,
               r->active ? "true" : "false",
               (unsigned long)r->call_count, r->total_latency_ms);
    }
    APPEND("]");

    APPEND("}");
#undef APPEND

    return off;
}

/* ---------- dump ---------- */

static const char *state_name(int s) {
    switch (s) {
    case LDX_SHARD_RUNNING:   return "running";
    case LDX_SHARD_SUSPENDED: return "suspended";
    case LDX_SHARD_MIGRATING: return "migrating";
    default:                  return "stopped";
    }
}

void ldx_registry_dump(const ldx_topology_t *topo)
{
    fprintf(stderr, "\n=== ldx topology ===\n");

    fprintf(stderr, "Nodes (%d):\n", topo->n_nodes);
    for (int i = 0; i < topo->n_nodes; i++) {
        const ldx_node_t *n = &topo->nodes[i];
        fprintf(stderr, "  [%d] %s @ %s:%d  (%d cores, %luMB, %s, %d shards)\n",
                n->id, n->name, n->host, n->port,
                n->n_cores, (unsigned long)n->memory_mb, n->arch, n->n_shards);
    }

    fprintf(stderr, "Shards (%d):\n", topo->n_shards);
    for (int i = 0; i < topo->n_shards; i++) {
        const ldx_shard_t *s = &topo->shards[i];
        fprintf(stderr, "  [%d] %s  node=%d  state=%s  host=%s  ctl=%d  pipe=%d  funcs=%d\n",
                s->id, s->name, s->node_id, state_name(s->state),
                s->host, s->control_port, s->pipe_port, s->n_funcs);
    }

    fprintf(stderr, "Functions (%d):\n", topo->n_functions);
    for (int i = 0; i < topo->n_functions; i++) {
        const ldx_function_t *f = &topo->functions[i];
        fprintf(stderr, "  [%d] %s → shard %d\n", f->id, f->name, f->owner_shard_id);
    }

    fprintf(stderr, "Routes (%d):\n", topo->n_routes);
    for (int i = 0; i < topo->n_routes; i++) {
        const ldx_route_t *r = &topo->routes[i];
        fprintf(stderr, "  [%d] shard %d → %s %d @ %s:%d  %s  (%lu calls)\n",
                r->id, r->from_shard_id,
                r->route_type == LDX_ROUTE_SYSCALL ? "OS" : "shard",
                r->to_shard_id, r->to_host, r->to_port,
                r->active ? "ACTIVE" : "inactive",
                (unsigned long)r->call_count);
    }
    fprintf(stderr, "====================\n\n");
}
