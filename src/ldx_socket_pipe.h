#ifndef LDX_SOCKET_PIPE_H
#define LDX_SOCKET_PIPE_H

/*
 * ldx_socket_pipe.h — Socket-backed Pipe<> that forwards syscalls
 * over a Unix domain socket (or later, TCP/IPv6).
 *
 * Two roles:
 *   Client (inside container): intercepts syscalls, serializes args,
 *     sends over socket, receives result.
 *   Server (on host): receives serialized args, executes the real
 *     syscall, sends result back.
 *
 * Wire protocol (per call):
 *   Request:  [uint32 name_len] [name] [uint32 args_size] [args_data]
 *   Response: [int32 errno_val] [uint32 ret_size] [ret_data]
 *             [uint32 n_outbufs] { [uint32 arg_idx] [uint32 size] [data] }...
 *
 * The outbufs section carries PTR_OUT/PTR_INOUT data back to the client
 * (e.g., the buffer filled by read(), the struct stat from stat()).
 */

#include "ldx_pipe.h"
#include <cstdint>
#include <cstring>
#include <string>

namespace ldx {

/* Wire protocol helpers. */
struct SockMsg {
    static bool send_all(int fd, const void *buf, size_t len);
    static bool recv_all(int fd, void *buf, size_t len);
    static bool send_u32(int fd, uint32_t v);
    static bool recv_u32(int fd, uint32_t *v);
    static bool send_i32(int fd, int32_t v);
    static bool recv_i32(int fd, int32_t *v);
    static bool send_buf(int fd, const void *buf, size_t len);
    static bool recv_buf(int fd, void *buf, size_t max, uint32_t *actual);
};

/*
 * SocketPipe<Args, Ret> — client side.
 *
 * Overrides propagate() to serialize Args, send over socket,
 * receive Ret + output buffers.
 *
 * Args struct must additionally define:
 *   static const char *syscall_name();
 *   void write_outbufs(int sockfd) const;  // send PTR_OUT buffer info
 *   void read_outbufs(int sockfd);          // receive filled PTR_OUT data
 *
 * For simple all-value syscalls, write_outbufs/read_outbufs are no-ops.
 */
template<typename Args, typename Ret>
class SocketPipe : public Pipe<Args, Ret> {
public:
    SocketPipe(void *original, int sockfd)
        : Pipe<Args, Ret>(original), sockfd_(sockfd) {}

    Ret propagate() override {
        /* Send request: name + args. */
        const char *name = Args::syscall_name();
        uint32_t nlen = (uint32_t)strlen(name);
        SockMsg::send_u32(sockfd_, nlen);
        SockMsg::send_all(sockfd_, name, nlen);
        SockMsg::send_u32(sockfd_, (uint32_t)sizeof(Args));
        SockMsg::send_all(sockfd_, &this->stored_, sizeof(Args));

        /* Send output buffer descriptors (sizes the server needs to know). */
        this->stored_.write_outbufs(sockfd_);

        /* Receive response: errno + return value. */
        int32_t err = 0;
        SockMsg::recv_i32(sockfd_, &err);

        Ret result{};
        uint32_t retsz = 0;
        SockMsg::recv_u32(sockfd_, &retsz);
        if (retsz > 0 && retsz <= sizeof(Ret))
            SockMsg::recv_all(sockfd_, &result, retsz);

        /* Receive output buffers (filled PTR_OUT data). */
        this->stored_.read_outbufs(sockfd_);

        if (err != 0)
            errno = err;

        return result;
    }

    int sockfd() const { return sockfd_; }
    void set_sockfd(int fd) { sockfd_ = fd; }

protected:
    int sockfd_;
};

/* Void specialization. */
template<typename Args>
class SocketPipe<Args, void> : public Pipe<Args, void> {
public:
    SocketPipe(void *original, int sockfd)
        : Pipe<Args, void>(original), sockfd_(sockfd) {}

    void propagate() override {
        const char *name = Args::syscall_name();
        uint32_t nlen = (uint32_t)strlen(name);
        SockMsg::send_u32(sockfd_, nlen);
        SockMsg::send_all(sockfd_, name, nlen);
        SockMsg::send_u32(sockfd_, (uint32_t)sizeof(Args));
        SockMsg::send_all(sockfd_, &this->stored_, sizeof(Args));
        this->stored_.write_outbufs(sockfd_);

        int32_t err = 0;
        SockMsg::recv_i32(sockfd_, &err);
        /* skip return value for void */
        uint32_t retsz = 0;
        SockMsg::recv_u32(sockfd_, &retsz);

        this->stored_.read_outbufs(sockfd_);

        if (err != 0)
            errno = err;
    }

    int sockfd() const { return sockfd_; }
    void set_sockfd(int fd) { sockfd_ = fd; }

protected:
    int sockfd_;
};

} /* namespace ldx */

/*
 * Server-side dispatcher: receives requests on a socket,
 * executes the real syscall, sends results back.
 */
#ifdef __cplusplus
extern "C" {
#endif

/* Callback type: given a syscall name and raw args buffer, execute
 * the syscall and return the result.  The server registers one per
 * supported syscall. */
typedef struct {
    const char *name;
    /* Execute the syscall.  args points to the Args struct.
     * Fill ret_buf with return value.  Fill outbufs and send them.
     * Returns errno (0 on success). */
    int (*execute)(const void *args, size_t args_size,
                   void *ret_buf, size_t ret_size,
                   int sockfd);
} ldx_sock_handler_t;

/* Run the server loop on the given socket fd.
 * Dispatches incoming requests to registered handlers.
 * Returns when the socket is closed. */
int ldx_sock_server_run(int sockfd, const ldx_sock_handler_t *handlers, int nhandlers);

#ifdef __cplusplus
}
#endif

#endif /* LDX_SOCKET_PIPE_H */
