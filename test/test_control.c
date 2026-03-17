/*
 * test_control.c — Test the control socket for container orchestration.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "../src/ldx_control.h"

static int failures = 0;

static void check(int cond, const char *name, const char *msg) {
    if (cond) {
        printf("%s: PASS\n", name);
    } else {
        printf("%s: FAIL (%s)\n", name, msg);
        failures++;
    }
}

/* Send a command to the control socket and receive response. */
static int send_cmd(int port, const char *cmd, char *resp, size_t resp_sz)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
    };
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    char buf[512];
    int n = snprintf(buf, sizeof(buf), "%s\n", cmd);
    write(fd, buf, n);

    /* Read response. */
    ssize_t nr = read(fd, resp, resp_sz - 1);
    if (nr > 0) resp[nr] = '\0';
    else resp[0] = '\0';

    close(fd);
    return 0;
}

int main(void)
{
    printf("=== ldx control tests ===\n");

    /* Start control server. */
    int port = ldx_control_start(0);  /* auto-assign port */
    check(port > 0, "test_start", "control server started");
    printf("  control port: %d\n", port);

    /* Give server thread time to start. */
    usleep(50000);

    /* Test status command. */
    char resp[512];
    int rc = send_cmd(port, "{\"cmd\":\"status\"}", resp, sizeof(resp));
    check(rc == 0, "test_status_connect", "connect to control");
    check(strstr(resp, "\"ok\":true") != NULL, "test_status_ok", resp);
    check(strstr(resp, "\"disconnected\"") != NULL, "test_status_disconnected", resp);
    printf("  status: %s", resp);

    /* Test disconnect (already disconnected — should still succeed). */
    rc = send_cmd(port, "{\"cmd\":\"disconnect\"}", resp, sizeof(resp));
    check(rc == 0 && strstr(resp, "\"ok\":true") != NULL, "test_disconnect", resp);

    /* Test suspend. */
    rc = send_cmd(port, "{\"cmd\":\"suspend\"}", resp, sizeof(resp));
    check(rc == 0 && strstr(resp, "\"suspended\"") != NULL, "test_suspend", resp);

    /* Test resume. */
    rc = send_cmd(port, "{\"cmd\":\"resume\"}", resp, sizeof(resp));
    check(rc == 0 && strstr(resp, "\"ok\":true") != NULL, "test_resume", resp);

    /* Test unknown command. */
    rc = send_cmd(port, "{\"cmd\":\"foobar\"}", resp, sizeof(resp));
    check(rc == 0 && strstr(resp, "\"ok\":false") != NULL, "test_unknown_cmd", resp);

    /* Test reconnect to a non-existent server (should fail gracefully). */
    rc = send_cmd(port, "{\"cmd\":\"reconnect\",\"host\":\"127.0.0.1\",\"port\":1}", resp, sizeof(resp));
    check(rc == 0 && strstr(resp, "\"ok\":false") != NULL, "test_reconnect_fail", resp);

    ldx_control_stop();

    printf("=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
