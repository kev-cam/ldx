/*
 * ldx-server — Standalone pipe-os server.
 *
 * Listens on a TCP port, accepts one connection from a container,
 * and executes syscalls on its behalf.
 *
 * Usage: ldx-server [--port PORT]
 */
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

extern "C" {
#include "ldx.h"
}
#include "ldx_syscall_pbv.h"

int main(int argc, char **argv)
{
    int port = 9801;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            port = atoi(argv[++i]);
    }

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind"); return 1;
    }
    if (listen(listen_fd, 1) != 0) {
        perror("listen"); return 1;
    }

    fprintf(stderr, "ldx-server: listening on port %d\n", port);

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t addrlen = sizeof(client_addr);
        int client_fd = accept(listen_fd, (struct sockaddr *)&client_addr, &addrlen);
        if (client_fd < 0) { perror("accept"); continue; }

        char client_ip[64];
        inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, sizeof(client_ip));
        fprintf(stderr, "ldx-server: connection from %s:%d\n",
                client_ip, ntohs(client_addr.sin_port));

        ldx_syscall_sock_server(client_fd);

        fprintf(stderr, "ldx-server: client disconnected\n");
        close(client_fd);
    }

    close(listen_fd);
    return 0;
}
