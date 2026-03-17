#define _GNU_SOURCE
#include "ldx_control.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>

/* ---------- state ---------- */

static int ctl_state = LDX_STATE_DISCONNECTED;
static int ctl_pipe_fd = -1;
static int ctl_listen_fd = -1;
static int ctl_port = 0;
static int ctl_running = 0;
static pthread_t ctl_thread;
static pthread_mutex_t ctl_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ctl_resume_cond = PTHREAD_COND_INITIALIZER;
static ldx_pipe_rewire_fn ctl_rewire_fn = NULL;

/* ---------- public getters/setters ---------- */

int ldx_control_get_state(void)
{
    pthread_mutex_lock(&ctl_lock);
    int s = ctl_state;
    pthread_mutex_unlock(&ctl_lock);
    return s;
}

int ldx_control_get_pipe_fd(void)
{
    pthread_mutex_lock(&ctl_lock);
    int fd = ctl_pipe_fd;
    pthread_mutex_unlock(&ctl_lock);
    return fd;
}

int ldx_control_set_pipe_fd(int new_fd)
{
    pthread_mutex_lock(&ctl_lock);
    ctl_pipe_fd = new_fd;
    if (new_fd >= 0)
        ctl_state = LDX_STATE_CONNECTED;
    else
        ctl_state = LDX_STATE_DISCONNECTED;

    if (ctl_rewire_fn)
        ctl_rewire_fn(new_fd);

    /* Wake any suspended syscalls. */
    pthread_cond_broadcast(&ctl_resume_cond);
    pthread_mutex_unlock(&ctl_lock);
    return 0;
}

void ldx_control_set_rewire_callback(ldx_pipe_rewire_fn fn)
{
    pthread_mutex_lock(&ctl_lock);
    ctl_rewire_fn = fn;
    pthread_mutex_unlock(&ctl_lock);
}

/* ---------- disconnect / reconnect ---------- */

int ldx_control_disconnect(void)
{
    pthread_mutex_lock(&ctl_lock);
    if (ctl_pipe_fd >= 0) {
        close(ctl_pipe_fd);
        ctl_pipe_fd = -1;
    }
    ctl_state = LDX_STATE_DISCONNECTED;
    if (ctl_rewire_fn)
        ctl_rewire_fn(-1);
    pthread_mutex_unlock(&ctl_lock);

    fprintf(stderr, "ldx-control: disconnected\n");
    return 0;
}

int ldx_control_reconnect(const char *host, int port)
{
    /* Create TCP connection to new server. */
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("ldx-control: socket");
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
        /* Try hostname resolution. */
        struct hostent *he = gethostbyname(host);
        if (!he) {
            fprintf(stderr, "ldx-control: cannot resolve %s\n", host);
            close(sockfd);
            return -1;
        }
        memcpy(&addr.sin_addr, he->h_addr_list[0], sizeof(addr.sin_addr));
    }

    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        fprintf(stderr, "ldx-control: connect to %s:%d failed: %s\n",
                host, port, strerror(errno));
        close(sockfd);
        return -1;
    }

    /* Rewire all pipes to new fd. */
    pthread_mutex_lock(&ctl_lock);
    if (ctl_pipe_fd >= 0)
        close(ctl_pipe_fd);
    ctl_pipe_fd = sockfd;
    ctl_state = LDX_STATE_CONNECTED;
    if (ctl_rewire_fn)
        ctl_rewire_fn(sockfd);
    pthread_cond_broadcast(&ctl_resume_cond);
    pthread_mutex_unlock(&ctl_lock);

    fprintf(stderr, "ldx-control: reconnected to %s:%d (fd=%d)\n", host, port, sockfd);
    return 0;
}

int ldx_control_suspend(void)
{
    pthread_mutex_lock(&ctl_lock);
    ctl_state = LDX_STATE_SUSPENDED;
    pthread_mutex_unlock(&ctl_lock);
    fprintf(stderr, "ldx-control: suspended\n");
    return 0;
}

int ldx_control_resume(void)
{
    pthread_mutex_lock(&ctl_lock);
    if (ctl_pipe_fd >= 0)
        ctl_state = LDX_STATE_CONNECTED;
    else
        ctl_state = LDX_STATE_DISCONNECTED;
    pthread_cond_broadcast(&ctl_resume_cond);
    pthread_mutex_unlock(&ctl_lock);
    fprintf(stderr, "ldx-control: resumed\n");
    return 0;
}

/* ---------- JSON helpers (minimal, no dependency) ---------- */

/* Extract string value for a key from a JSON object.
 * Writes into out (max out_sz).  Returns 0 on success. */
static int json_get_str(const char *json, const char *key, char *out, size_t out_sz)
{
    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return -1;
    p += strlen(search);
    while (*p == ' ' || *p == ':') p++;
    if (*p != '"') return -1;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i < out_sz - 1)
        out[i++] = *p++;
    out[i] = '\0';
    return 0;
}

/* Extract integer value for a key. */
static int json_get_int(const char *json, const char *key, int *out)
{
    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p) return -1;
    p += strlen(search);
    while (*p == ' ' || *p == ':') p++;
    *out = atoi(p);
    return 0;
}

/* ---------- command handler ---------- */

static void handle_command(int client_fd, const char *line)
{
    char cmd[64] = {};
    char resp[512];

    json_get_str(line, "cmd", cmd, sizeof(cmd));

    if (strcmp(cmd, "status") == 0) {
        const char *state_str;
        pthread_mutex_lock(&ctl_lock);
        switch (ctl_state) {
        case LDX_STATE_CONNECTED:    state_str = "connected"; break;
        case LDX_STATE_DISCONNECTED: state_str = "disconnected"; break;
        case LDX_STATE_SUSPENDED:    state_str = "suspended"; break;
        default:                     state_str = "unknown"; break;
        }
        snprintf(resp, sizeof(resp),
                 "{\"ok\":true,\"state\":\"%s\",\"pipe_fd\":%d,\"port\":%d}\n",
                 state_str, ctl_pipe_fd, ctl_port);
        pthread_mutex_unlock(&ctl_lock);
    }
    else if (strcmp(cmd, "disconnect") == 0) {
        ldx_control_disconnect();
        snprintf(resp, sizeof(resp),
                 "{\"ok\":true,\"state\":\"disconnected\"}\n");
    }
    else if (strcmp(cmd, "reconnect") == 0) {
        char host[256] = {};
        int port = 0;
        json_get_str(line, "host", host, sizeof(host));
        json_get_int(line, "port", &port);

        if (host[0] && port > 0) {
            int rc = ldx_control_reconnect(host, port);
            if (rc == 0)
                snprintf(resp, sizeof(resp),
                         "{\"ok\":true,\"state\":\"connected\",\"pipe_fd\":%d}\n",
                         ldx_control_get_pipe_fd());
            else
                snprintf(resp, sizeof(resp),
                         "{\"ok\":false,\"error\":\"connect failed\"}\n");
        } else {
            snprintf(resp, sizeof(resp),
                     "{\"ok\":false,\"error\":\"need host and port\"}\n");
        }
    }
    else if (strcmp(cmd, "suspend") == 0) {
        ldx_control_suspend();
        snprintf(resp, sizeof(resp),
                 "{\"ok\":true,\"state\":\"suspended\"}\n");
    }
    else if (strcmp(cmd, "resume") == 0) {
        ldx_control_resume();
        snprintf(resp, sizeof(resp),
                 "{\"ok\":true,\"state\":\"connected\"}\n");
    }
    else {
        snprintf(resp, sizeof(resp),
                 "{\"ok\":false,\"error\":\"unknown command: %s\"}\n", cmd);
    }

    /* Send response. */
    write(client_fd, resp, strlen(resp));
}

/* ---------- server thread ---------- */

static void handle_client(int client_fd)
{
    char buf[1024];
    ssize_t total = 0;

    /* Read lines until connection closes. */
    while (1) {
        ssize_t n = read(client_fd, buf + total, sizeof(buf) - 1 - total);
        if (n <= 0) break;
        total += n;
        buf[total] = '\0';

        /* Process complete lines. */
        char *nl;
        while ((nl = strchr(buf, '\n')) != NULL) {
            *nl = '\0';
            if (buf[0])
                handle_command(client_fd, buf);
            /* Shift remaining data. */
            size_t consumed = (size_t)(nl - buf + 1);
            total -= consumed;
            memmove(buf, nl + 1, total + 1);
        }
    }

    close(client_fd);
}

static void *ctl_server_loop(void *arg)
{
    (void)arg;

    while (ctl_running) {
        struct sockaddr_in client_addr;
        socklen_t addrlen = sizeof(client_addr);
        int client_fd = accept(ctl_listen_fd,
                               (struct sockaddr *)&client_addr, &addrlen);
        if (client_fd < 0) {
            if (ctl_running)
                perror("ldx-control: accept");
            break;
        }

        /* Handle one client at a time (simple). */
        handle_client(client_fd);
    }

    return NULL;
}

/* ---------- start / stop ---------- */

int ldx_control_start(int port)
{
    ctl_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ctl_listen_fd < 0) {
        perror("ldx-control: socket");
        return -1;
    }

    int opt = 1;
    setsockopt(ctl_listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(ctl_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        /* Try next port if requested port is busy. */
        if (port != 0) {
            addr.sin_port = 0;
            if (bind(ctl_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
                perror("ldx-control: bind");
                close(ctl_listen_fd);
                return -1;
            }
        } else {
            perror("ldx-control: bind");
            close(ctl_listen_fd);
            return -1;
        }
    }

    /* Get actual port. */
    socklen_t addrlen = sizeof(addr);
    getsockname(ctl_listen_fd, (struct sockaddr *)&addr, &addrlen);
    ctl_port = ntohs(addr.sin_port);

    if (listen(ctl_listen_fd, 4) != 0) {
        perror("ldx-control: listen");
        close(ctl_listen_fd);
        return -1;
    }

    ctl_running = 1;

    if (pthread_create(&ctl_thread, NULL, ctl_server_loop, NULL) != 0) {
        perror("ldx-control: pthread_create");
        close(ctl_listen_fd);
        return -1;
    }
    pthread_detach(ctl_thread);

    fprintf(stderr, "ldx-control: listening on port %d\n", ctl_port);
    return ctl_port;
}

void ldx_control_stop(void)
{
    ctl_running = 0;
    if (ctl_listen_fd >= 0) {
        close(ctl_listen_fd);
        ctl_listen_fd = -1;
    }
}
