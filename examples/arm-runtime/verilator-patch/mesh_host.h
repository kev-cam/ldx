// mesh_host.h — A53-side wander_call into the 5x5 ldx mesh.
//
// The bridge sits at PS physical 0xA0000000 (128 KB). One call to
// mesh_init() mmaps it, loads firmware into all 25 cores, and releases
// reset. mesh_call() then issues a blocking remote call.

#ifndef MESH_HOST_H
#define MESH_HOST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int      mesh_init(const char *firmware_bin_path);
uint32_t mesh_call(unsigned dx, unsigned dy, unsigned fn,
                   unsigned argc, const uint32_t *args);
void     mesh_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
