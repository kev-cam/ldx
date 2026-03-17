/*
 * test_registry.c — Test the topology registry.
 */
#include <stdio.h>
#include <string.h>
#include "../src/ldx_registry.h"

static int failures = 0;

static void check(int cond, const char *name) {
    if (cond) printf("%s: PASS\n", name);
    else { printf("%s: FAIL\n", name); failures++; }
}

int main(void)
{
    printf("=== ldx registry tests ===\n");
    ldx_topology_t topo;
    ldx_registry_init(&topo);

    /* Add nodes. */
    int n0 = ldx_registry_add_node(&topo, "kc-clevo", "192.168.15.107", 22, 8, 32768, "x86_64");
    int n1 = ldx_registry_add_node(&topo, "zmc1", "192.168.15.222", 22, 16, 65536, "x86_64");
    int n2 = ldx_registry_add_node(&topo, "fpga-board", "192.168.15.50", 22, 4, 4096, "fpga");
    check(n0 == 0 && n1 == 1 && n2 == 2, "add_nodes");
    check(topo.n_nodes == 3, "node_count");

    /* Add shards (simulating a MySQL-like app). */
    int s_query = ldx_registry_add_shard(&topo, "mysql-query");
    int s_storage = ldx_registry_add_shard(&topo, "mysql-storage");
    int s_cache = ldx_registry_add_shard(&topo, "mysql-cache");
    check(s_query == 0 && s_storage == 1 && s_cache == 2, "add_shards");

    /* Register functions. */
    int f0 = ldx_registry_add_function(&topo, "mysql_real_query", s_query);
    int f1 = ldx_registry_add_function(&topo, "mysql_store_result", s_storage);
    int f2 = ldx_registry_add_function(&topo, "mysql_fetch_row", s_query);
    int f3 = ldx_registry_add_function(&topo, "cache_get", s_cache);
    int f4 = ldx_registry_add_function(&topo, "cache_put", s_cache);
    check(topo.n_functions == 5, "add_functions");

    /* Place shards on nodes. */
    ldx_registry_place_shard(&topo, s_query, n0);    /* query on kc-clevo */
    ldx_registry_place_shard(&topo, s_storage, n1);   /* storage on zmc1 */
    ldx_registry_place_shard(&topo, s_cache, n0);     /* cache co-located with query */

    check(strcmp(topo.shards[s_query].host, "192.168.15.107") == 0, "place_query");
    check(strcmp(topo.shards[s_storage].host, "192.168.15.222") == 0, "place_storage");
    check(topo.nodes[n0].n_shards == 2, "node0_shards");
    check(topo.nodes[n1].n_shards == 1, "node1_shards");

    /* Set shard state. */
    ldx_registry_set_shard_state(&topo, s_query, LDX_SHARD_RUNNING);
    ldx_registry_set_shard_state(&topo, s_storage, LDX_SHARD_RUNNING);
    ldx_registry_set_shard_state(&topo, s_cache, LDX_SHARD_RUNNING);
    topo.shards[s_query].control_port = 9800;
    topo.shards[s_storage].control_port = 9800;
    topo.shards[s_cache].control_port = 9800;
    topo.shards[s_query].pipe_port = 9801;
    topo.shards[s_storage].pipe_port = 9801;
    topo.shards[s_cache].pipe_port = 9801;

    /* Add routes. */
    int r0 = ldx_registry_add_route(&topo, s_query, -1, LDX_ROUTE_SYSCALL,
                                     "192.168.15.107", 9801);
    int r1 = ldx_registry_add_route(&topo, s_query, s_storage, LDX_ROUTE_FUNCTION,
                                     "", 0);
    int r2 = ldx_registry_add_route(&topo, s_query, s_cache, LDX_ROUTE_FUNCTION,
                                     "", 0);
    int r3 = ldx_registry_add_route(&topo, s_storage, -1, LDX_ROUTE_SYSCALL,
                                     "192.168.15.222", 9801);
    check(topo.n_routes == 4, "add_routes");

    /* Resolve routes. */
    int resolved = ldx_registry_resolve_routes(&topo, s_query);
    check(resolved == 2, "resolve_routes");
    check(strcmp(topo.routes[r1].to_host, "192.168.15.222") == 0, "route_to_storage");
    check(strcmp(topo.routes[r2].to_host, "192.168.15.107") == 0, "route_to_cache");

    /* Lookup route by function name. */
    ldx_route_t *route = ldx_registry_lookup_route(&topo, s_query, "mysql_store_result");
    check(route != NULL && route->to_shard_id == s_storage, "lookup_route");

    ldx_route_t *route2 = ldx_registry_lookup_route(&topo, s_query, "cache_get");
    check(route2 != NULL && route2->to_shard_id == s_cache, "lookup_cache_route");

    /* Migrate storage shard from zmc1 to fpga-board. */
    ldx_registry_migrate_shard(&topo, s_storage, n2);
    check(topo.shards[s_storage].node_id == n2, "migrate_node");
    check(strcmp(topo.shards[s_storage].host, "192.168.15.50") == 0, "migrate_host");
    check(topo.shards[s_storage].state == LDX_SHARD_MIGRATING, "migrate_state");

    /* After migration, route from query to storage should point to fpga. */
    check(strcmp(topo.routes[r1].to_host, "192.168.15.50") == 0, "migrate_route_updated");
    check(topo.nodes[n1].n_shards == 0, "old_node_cleared");
    check(topo.nodes[n2].n_shards == 1, "new_node_populated");

    /* Move function from one shard to another. */
    ldx_registry_move_function(&topo, f3, s_query);  /* cache_get → query shard */
    check(topo.functions[f3].owner_shard_id == s_query, "move_function");
    check(topo.shards[s_cache].n_funcs == 1, "old_shard_func_removed");
    check(topo.shards[s_query].n_funcs == 3, "new_shard_func_added");

    /* JSON serialization. */
    char json[8192];
    int len = ldx_registry_to_json(&topo, json, sizeof(json));
    check(len > 100, "json_serialize");
    check(strstr(json, "mysql-query") != NULL, "json_has_shard");
    check(strstr(json, "fpga-board") != NULL, "json_has_node");
    check(strstr(json, "cache_get") != NULL, "json_has_function");

    /* Dump for visual inspection. */
    ldx_registry_dump(&topo);

    printf("=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
