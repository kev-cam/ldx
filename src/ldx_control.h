#ifndef LDX_CONTROL_H
#define LDX_CONTROL_H

/*
 * ldx_control.h — Control socket for container orchestration.
 *
 * Listens on a TCP port inside the container.  Accepts JSON commands
 * for status, disconnect, reconnect, suspend, resume.
 *
 * Wire protocol (per command):
 *   Client sends: one line of JSON + newline
 *   Server replies: one line of JSON + newline
 *
 * Commands:
 *   {"cmd":"status"}
 *     → {"ok":true,"state":"connected","pipe_fd":5,"port":9800,"syscalls":53}
 *
 *   {"cmd":"disconnect"}
 *     → {"ok":true,"state":"disconnected"}
 *     Closes the pipe-os socket.  Syscalls will block/fail until reconnect.
 *
 *   {"cmd":"reconnect","host":"192.168.1.100","port":9801}
 *     → {"ok":true,"state":"connected","pipe_fd":7}
 *     Connects to a new pipe-os server on the given host:port.
 *     All SocketPipes are rewired to the new fd.
 *
 *   {"cmd":"suspend"}
 *     → {"ok":true,"state":"suspended"}
 *     Pauses all piped syscalls (they block until resume).
 *
 *   {"cmd":"resume"}
 *     → {"ok":true,"state":"connected"}
 *     Unpauses piped syscalls.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Container pipe state. */
#define LDX_STATE_CONNECTED    0
#define LDX_STATE_DISCONNECTED 1
#define LDX_STATE_SUSPENDED    2

/* Start the control server on the given TCP port.
 * Runs in a background thread.  Returns 0 on success. */
int ldx_control_start(int port);

/* Stop the control server. */
void ldx_control_stop(void);

/* Get the current pipe state. */
int ldx_control_get_state(void);

/* Get/set the active pipe-os socket fd.
 * When disconnected, returns -1.
 * When reconnecting, all SocketPipes are rewired. */
int ldx_control_get_pipe_fd(void);
int ldx_control_set_pipe_fd(int new_fd);

/* Disconnect the pipe-os socket.  Syscalls will fail with ENOLINK. */
int ldx_control_disconnect(void);

/* Reconnect to a new pipe-os server at host:port.
 * Creates a TCP connection and rewires all SocketPipes. */
int ldx_control_reconnect(const char *host, int port);

/* Suspend/resume piped syscalls. */
int ldx_control_suspend(void);
int ldx_control_resume(void);

/* Register a SocketPipe fd setter — called when pipe fd changes.
 * The callback receives the new fd (or -1 on disconnect). */
typedef void (*ldx_pipe_rewire_fn)(int new_fd);
void ldx_control_set_rewire_callback(ldx_pipe_rewire_fn fn);

#ifdef __cplusplus
}
#endif

#endif /* LDX_CONTROL_H */
