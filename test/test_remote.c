/*
 * test_remote.c — Test program for remote execution via pipe-os.
 *
 * Performs various syscalls that should be piped to the server.
 * When run locally, uses local OS. When run via ldx socket pipes,
 * syscalls execute on the server machine.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <fcntl.h>

int main(void)
{
    printf("=== ldx remote test ===\n");

    /* 1. Hostname — should show the server's hostname when piped. */
    char hostname[256] = {};
    gethostname(hostname, sizeof(hostname));
    printf("hostname: %s\n", hostname);

    /* 2. PID and UID. */
    printf("pid: %d\n", getpid());
    printf("uid: %d\n", getuid());

    /* 3. Read a file. */
    const char *test_path = "/tmp/ldx_remote_test.txt";
    int fd = open(test_path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *msg = "hello from remote!\n";
        write(fd, msg, strlen(msg));
        close(fd);
        printf("wrote: %s to %s\n", msg, test_path);

        /* Read it back. */
        fd = open(test_path, O_RDONLY);
        if (fd >= 0) {
            char buf[256] = {};
            ssize_t n = read(fd, buf, sizeof(buf) - 1);
            close(fd);
            printf("read back: %s", buf);
        }
        unlink(test_path);
    } else {
        printf("open failed (expected if piped without full OS)\n");
    }

    /* 4. stat /tmp. */
    struct stat st;
    if (stat("/tmp", &st) == 0) {
        printf("stat /tmp: mode=%o, size=%ld\n",
               st.st_mode & 07777, (long)st.st_size);
    }

    /* 5. Current directory. */
    char cwd[1024] = {};
    if (getcwd(cwd, sizeof(cwd)))
        printf("cwd: %s\n", cwd);

    printf("=== done ===\n");
    return 0;
}
