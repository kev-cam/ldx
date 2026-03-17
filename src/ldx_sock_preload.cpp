/*
 * ldx_sock_preload.cpp — LD_PRELOAD library that connects to a remote
 * pipe-os server and routes syscalls over the socket.
 *
 * Environment variables:
 *   LDX_SERVER_HOST  — server hostname/IP (default: 127.0.0.1)
 *   LDX_SERVER_PORT  — server port (default: 9801)
 *   LDX_CONTROL_PORT — control socket port (default: 9800, 0 to disable)
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>

extern "C" {
#include "ldx.h"
#include "ldx_control.h"
}
#include "ldx_syscall_pbv.h"

static int connect_to_server(const char *host, int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        struct hostent *he = gethostbyname(host);
        if (he)
            memcpy(&addr.sin_addr, he->h_addr_list[0], sizeof(addr.sin_addr));
        else {
            close(fd);
            return -1;
        }
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    return fd;
}

__attribute__((constructor))
static void ldx_sock_preload_init(void)
{
    const char *host = getenv("LDX_SERVER_HOST");
    const char *port_str = getenv("LDX_SERVER_PORT");
    const char *ctl_port_str = getenv("LDX_CONTROL_PORT");

    if (!host) host = "127.0.0.1";
    int port = port_str ? atoi(port_str) : 9801;
    int ctl_port = ctl_port_str ? atoi(ctl_port_str) : 9800;

    fprintf(stderr, "ldx-sock-preload: connecting to %s:%d\n", host, port);

    int sockfd = connect_to_server(host, port);
    if (sockfd < 0) {
        fprintf(stderr, "ldx-sock-preload: failed to connect to %s:%d\n", host, port);
        return;
    }

    fprintf(stderr, "ldx-sock-preload: connected (fd=%d)\n", sockfd);

    /* Install socket pipe wrappers. */
    int n = ldx_syscall_sock_init(sockfd);
    fprintf(stderr, "ldx-sock-preload: %d syscalls piped\n", n);

    /* Start control socket. */
    if (ctl_port >= 0) {
        int actual_port = ldx_control_start(ctl_port);
        if (actual_port > 0)
            fprintf(stderr, "ldx-sock-preload: control on port %d\n", actual_port);
    }
}
