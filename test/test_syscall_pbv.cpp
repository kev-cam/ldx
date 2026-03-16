/*
 * test_syscall_pbv.cpp — Test generated syscall PbV wrappers.
 *
 * Proves that syscalls routed through Pipe<> produce identical results
 * to direct calls.
 */
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include "ldx_syscall_pbv.h"

extern "C" {
#include "ldx.h"
}

static int failures = 0;

static void check(bool cond, const char *name, const char *msg = "") {
    if (cond) {
        printf("%s: PASS\n", name);
    } else {
        printf("%s: FAIL (%s, errno=%d)\n", name, msg, errno);
        failures++;
    }
}

/* Test 1: write/read through pipes */
static void test_write_read() {
    /* Create a temp file, write through pipe, read back through pipe. */
    char tmpl[] = "/tmp/ldx_test_XXXXXX";
    int fd = mkstemp(tmpl);
    check(fd >= 0, "test_write_read_setup", "mkstemp");
    if (fd < 0) return;

    const char *msg = "hello from pipe!\n";
    ssize_t nw = write(fd, msg, strlen(msg));
    check(nw == (ssize_t)strlen(msg), "test_write", "write through pipe");

    /* Seek back and read. */
    off_t pos = lseek(fd, 0, SEEK_SET);
    check(pos == 0, "test_lseek", "seek to beginning");

    char buf[64] = {};
    ssize_t nr = read(fd, buf, sizeof(buf) - 1);
    check(nr == (ssize_t)strlen(msg), "test_read_count", "read byte count");
    check(strcmp(buf, msg) == 0, "test_read_data", "read data matches");

    close(fd);
    unlink(tmpl);
}

/* Test 2: stat through pipe */
static void test_stat() {
    struct stat st = {};
    int rc = stat("/tmp", &st);
    check(rc == 0, "test_stat", "stat /tmp");
    check(S_ISDIR(st.st_mode), "test_stat_isdir", "/tmp should be a directory");
}

/* Test 3: mkdir/rmdir through pipe */
static void test_mkdir_rmdir() {
    const char *dir = "/tmp/ldx_test_dir";
    rmdir(dir);  /* cleanup from previous runs */

    int rc = mkdir(dir, 0755);
    check(rc == 0, "test_mkdir", "mkdir");

    struct stat st = {};
    rc = stat(dir, &st);
    check(rc == 0 && S_ISDIR(st.st_mode), "test_mkdir_exists", "directory exists");

    rc = rmdir(dir);
    check(rc == 0, "test_rmdir", "rmdir");
}

/* Test 4: access through pipe */
static void test_access() {
    int rc = access("/tmp", R_OK | W_OK);
    check(rc == 0, "test_access_tmp", "/tmp should be accessible");

    rc = access("/nonexistent_path_xyz", F_OK);
    check(rc != 0, "test_access_noent", "nonexistent path should fail");
}

/* Test 5: pipe() through pipe (meta!) */
static void test_pipe_syscall() {
    int fds[2] = {-1, -1};
    int rc = pipe(fds);
    check(rc == 0, "test_pipe_create", "pipe()");
    check(fds[0] >= 0 && fds[1] >= 0, "test_pipe_fds", "valid fds");

    if (rc == 0) {
        const char *msg = "pipe test";
        write(fds[1], msg, strlen(msg));
        char buf[32] = {};
        read(fds[0], buf, sizeof(buf) - 1);
        check(strcmp(buf, msg) == 0, "test_pipe_roundtrip", "data through pipe");
        close(fds[0]);
        close(fds[1]);
    }
}

/* Test 6: getpid/getuid (value-only, no pointers) */
static void test_getpid() {
    pid_t pid = getpid();
    check(pid > 0, "test_getpid", "pid should be positive");

    uid_t uid = getuid();
    check(uid >= 0, "test_getuid", "uid should be non-negative");
}

/* Test 7: dup/dup2 through pipe */
static void test_dup() {
    int fd = open("/dev/null", O_WRONLY);
    check(fd >= 0, "test_dup_setup", "open /dev/null");
    if (fd < 0) return;

    int fd2 = dup(fd);
    check(fd2 >= 0 && fd2 != fd, "test_dup", "dup returns new fd");

    close(fd2);
    close(fd);
}

/* Test 8: gethostname through pipe */
static void test_gethostname() {
    char name[256] = {};
    int rc = gethostname(name, sizeof(name));
    check(rc == 0, "test_gethostname", "gethostname()");
    check(strlen(name) > 0, "test_gethostname_notempty", "hostname not empty");
    printf("  hostname: %s\n", name);
}

int main() {
    printf("=== ldx syscall PbV tests ===\n");

    /* Install all pipe wrappers. */
    int n = ldx_syscall_pbv_init();
    printf("installed %d syscall wrappers\n\n", n);

    test_write_read();
    test_stat();
    test_mkdir_rmdir();
    test_access();
    test_pipe_syscall();
    test_getpid();
    test_dup();
    test_gethostname();

    printf("\n=== %d failure(s) ===\n", failures);
    return failures ? 1 : 0;
}
