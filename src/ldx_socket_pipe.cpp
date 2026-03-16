#include "ldx_socket_pipe.h"

#include <cstdio>
#include <cstring>
#include <cerrno>
#include <unistd.h>
#include <sys/socket.h>

namespace ldx {

bool SockMsg::send_all(int fd, const void *buf, size_t len)
{
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t n = ::send(fd, p, len, MSG_NOSIGNAL);
        if (n <= 0) return false;
        p += n;
        len -= (size_t)n;
    }
    return true;
}

bool SockMsg::recv_all(int fd, void *buf, size_t len)
{
    char *p = (char *)buf;
    while (len > 0) {
        ssize_t n = ::recv(fd, p, len, MSG_WAITALL);
        if (n <= 0) return false;
        p += n;
        len -= (size_t)n;
    }
    return true;
}

bool SockMsg::send_u32(int fd, uint32_t v)   { return send_all(fd, &v, 4); }
bool SockMsg::recv_u32(int fd, uint32_t *v)  { return recv_all(fd, v, 4); }
bool SockMsg::send_i32(int fd, int32_t v)    { return send_all(fd, &v, 4); }
bool SockMsg::recv_i32(int fd, int32_t *v)   { return recv_all(fd, v, 4); }

bool SockMsg::send_buf(int fd, const void *buf, size_t len)
{
    uint32_t sz = (uint32_t)len;
    if (!send_u32(fd, sz)) return false;
    if (len > 0 && !send_all(fd, buf, len)) return false;
    return true;
}

bool SockMsg::recv_buf(int fd, void *buf, size_t max, uint32_t *actual)
{
    uint32_t sz = 0;
    if (!recv_u32(fd, &sz)) return false;
    if (actual) *actual = sz;
    if (sz > max) return false;
    if (sz > 0 && !recv_all(fd, buf, sz)) return false;
    return true;
}

} /* namespace ldx */

/* Server-side dispatcher. */
extern "C"
int ldx_sock_server_run(int sockfd, const ldx_sock_handler_t *handlers, int nhandlers)
{
    char name_buf[256];
    unsigned char args_buf[4096];
    unsigned char ret_buf[256];

    while (1) {
        /* Read request: name_len + name + args_size + args. */
        uint32_t nlen = 0;
        if (!ldx::SockMsg::recv_u32(sockfd, &nlen))
            break;  /* connection closed */

        if (nlen >= sizeof(name_buf)) {
            fprintf(stderr, "ldx-server: name too long (%u)\n", nlen);
            break;
        }
        if (!ldx::SockMsg::recv_all(sockfd, name_buf, nlen))
            break;
        name_buf[nlen] = '\0';

        uint32_t args_size = 0;
        if (!ldx::SockMsg::recv_u32(sockfd, &args_size))
            break;
        if (args_size > sizeof(args_buf)) {
            fprintf(stderr, "ldx-server: args too large (%u)\n", args_size);
            break;
        }
        if (args_size > 0 && !ldx::SockMsg::recv_all(sockfd, args_buf, args_size))
            break;

        /* Find handler. */
        const ldx_sock_handler_t *handler = nullptr;
        for (int i = 0; i < nhandlers; i++) {
            if (strcmp(handlers[i].name, name_buf) == 0) {
                handler = &handlers[i];
                break;
            }
        }

        if (!handler) {
            fprintf(stderr, "ldx-server: unknown syscall '%s'\n", name_buf);
            /* Send error response. */
            int32_t err = ENOSYS;
            ldx::SockMsg::send_i32(sockfd, err);
            ldx::SockMsg::send_u32(sockfd, 0);  /* no return data */
            ldx::SockMsg::send_u32(sockfd, 0);  /* no outbufs */
            continue;
        }

        /* Execute. */
        memset(ret_buf, 0, sizeof(ret_buf));
        errno = 0;
        int err = handler->execute(args_buf, args_size,
                                   ret_buf, sizeof(ret_buf),
                                   sockfd);

        /* Send response: errno + return value.
         * The handler is responsible for sending outbufs via the sockfd
         * as part of its execute() call. */
        ldx::SockMsg::send_i32(sockfd, (int32_t)err);

        /* For now, send the full ret_buf up to 8 bytes (covers all scalar returns). */
        uint32_t ret_size = 8;
        ldx::SockMsg::send_u32(sockfd, ret_size);
        ldx::SockMsg::send_all(sockfd, ret_buf, ret_size);
    }

    return 0;
}
