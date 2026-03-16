#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/syscall.h>
#include <linux/limits.h>
#include <fcntl.h>

/*
 * ldx_container.c — Minimal container launcher for ldx.
 *
 * Creates isolated namespaces (PID, mount, UTS, IPC, optionally net),
 * sets up a minimal rootfs with bind-mounts, installs LD_PRELOAD for
 * syscall piping, and execs the target binary.
 *
 * A Unix socket pair connects the container to the host for piped
 * syscalls (when --pipe-os is used).
 */

/* pivot_root is not in glibc — use syscall directly. */
static int pivot_root(const char *new_root, const char *put_old)
{
    return (int)syscall(SYS_pivot_root, new_root, put_old);
}

/* Resolve all shared library dependencies of a binary via ldd. */
struct deplist {
    char paths[256][PATH_MAX];
    int count;
};

static int collect_deps(const char *binary, struct deplist *deps)
{
    deps->count = 0;

    char cmd[PATH_MAX + 32];
    snprintf(cmd, sizeof(cmd), "ldd %s 2>/dev/null", binary);
    FILE *fp = popen(cmd, "r");
    if (!fp) return -1;

    char line[1024];
    while (fgets(line, sizeof(line), fp) && deps->count < 256) {
        /* ldd output: "	libfoo.so.1 => /lib/x86_64-linux-gnu/libfoo.so.1 (0x...)" */
        char *arrow = strstr(line, "=> ");
        if (arrow) {
            char *path = arrow + 3;
            char *space = strchr(path, ' ');
            if (space) *space = '\0';
            char *nl = strchr(path, '\n');
            if (nl) *nl = '\0';
            if (path[0] == '/')
                strncpy(deps->paths[deps->count++], path, PATH_MAX - 1);
        } else {
            /* Lines like "	/lib64/ld-linux-x86-64.so.2 (0x...)" */
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            char *space = strchr(p, ' ');
            if (space) *space = '\0';
            char *nl = strchr(p, '\n');
            if (nl) *nl = '\0';
            if (p[0] == '/' && access(p, F_OK) == 0)
                strncpy(deps->paths[deps->count++], p, PATH_MAX - 1);
        }
    }
    pclose(fp);
    return deps->count;
}

/* Ensure parent directories exist for a path under rootfs. */
static void ensure_parent_dirs(const char *path)
{
    char buf[PATH_MAX];
    strncpy(buf, path, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0755);
            *p = '/';
        }
    }
}

/* Bind-mount a file into the rootfs. */
static int bind_mount_file(const char *rootfs, const char *src)
{
    char dest[PATH_MAX];
    snprintf(dest, sizeof(dest), "%s%s", rootfs, src);

    ensure_parent_dirs(dest);

    /* Create mount point (empty file for files, dir for dirs). */
    struct stat st;
    if (stat(src, &st) != 0) return -1;

    if (S_ISDIR(st.st_mode)) {
        mkdir(dest, 0755);
    } else {
        int fd = open(dest, O_CREAT | O_WRONLY, 0644);
        if (fd >= 0) close(fd);
    }

    if (mount(src, dest, NULL, MS_BIND | MS_REC, NULL) != 0) {
        fprintf(stderr, "ldx-container: bind mount %s → %s failed: %s\n",
                src, dest, strerror(errno));
        return -1;
    }
    return 0;
}

/* Set up the minimal rootfs. */
static int setup_rootfs(const char *rootfs, const char *binary,
                        const char *libldx_path)
{
    /* Create rootfs directory structure. */
    char path[PATH_MAX];

    mkdir(rootfs, 0755);
    snprintf(path, sizeof(path), "%s/proc", rootfs);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/dev", rootfs);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/tmp", rootfs);
    mkdir(path, 0755);

    /* Bind-mount the binary. */
    char real_binary[PATH_MAX];
    if (!realpath(binary, real_binary)) {
        fprintf(stderr, "ldx-container: cannot resolve %s: %s\n",
                binary, strerror(errno));
        return -1;
    }
    if (bind_mount_file(rootfs, real_binary) != 0) return -1;

    /* Bind-mount shared library dependencies. */
    struct deplist deps;
    if (collect_deps(real_binary, &deps) < 0) return -1;

    for (int i = 0; i < deps.count; i++) {
        bind_mount_file(rootfs, deps.paths[i]);
    }

    /* Bind-mount the dynamic linker (ld-linux). */
    bind_mount_file(rootfs, "/lib64/ld-linux-x86-64.so.2");

    /* Bind-mount libldx_syscall.so for LD_PRELOAD. */
    if (libldx_path) {
        char real_lib[PATH_MAX];
        if (realpath(libldx_path, real_lib))
            bind_mount_file(rootfs, real_lib);
    }

    /* Bind-mount /dev/null, /dev/zero, /dev/urandom. */
    const char *devs[] = {"/dev/null", "/dev/zero", "/dev/urandom", NULL};
    for (int i = 0; devs[i]; i++)
        bind_mount_file(rootfs, devs[i]);

    /* Mount proc. */
    snprintf(path, sizeof(path), "%s/proc", rootfs);
    mount("proc", path, "proc", 0, NULL);

    return 0;
}

/* Do pivot_root into the new rootfs. */
static int do_pivot_root(const char *rootfs)
{
    char old_root[PATH_MAX];
    snprintf(old_root, sizeof(old_root), "%s/.old_root", rootfs);
    mkdir(old_root, 0755);

    if (pivot_root(rootfs, old_root) != 0) {
        fprintf(stderr, "ldx-container: pivot_root failed: %s\n", strerror(errno));
        return -1;
    }

    if (chdir("/") != 0) return -1;

    /* Unmount old root. */
    umount2("/.old_root", MNT_DETACH);
    rmdir("/.old_root");

    return 0;
}

/*
 * ldx_container_run — main entry point.
 *
 * Creates namespaces, sets up rootfs, optionally creates a socket pair
 * for OS piping, and execs the target.
 *
 * Returns: only on error (exec replaces the process on success).
 */
int ldx_container_run(int argc, char **argv, int pipe_os, int isolate_net)
{
    if (argc < 1) {
        fprintf(stderr, "ldx-container: no command specified\n");
        return 1;
    }

    const char *binary = argv[0];

    /* Verify binary exists. */
    if (access(binary, X_OK) != 0) {
        fprintf(stderr, "ldx-container: %s: %s\n", binary, strerror(errno));
        return 1;
    }

    /* Create socket pair for OS pipe (before unshare). */
    int sock_pair[2] = {-1, -1};
    if (pipe_os) {
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sock_pair) != 0) {
            perror("ldx-container: socketpair");
            return 1;
        }
    }

    /* Fork: parent runs the server, child becomes the container. */
    pid_t child = fork();
    if (child < 0) {
        perror("ldx-container: fork");
        return 1;
    }

    if (child > 0) {
        /* Parent — host side. */
        if (pipe_os) {
            close(sock_pair[1]);  /* close child's end */

            /* TODO: Run ldx_sock_server_run() here to handle piped
             * syscalls from the container.  For now, just wait. */
            fprintf(stderr, "ldx-container: host waiting (pipe_fd=%d)\n", sock_pair[0]);
        }

        int status;
        waitpid(child, &status, 0);

        if (pipe_os)
            close(sock_pair[0]);

        if (WIFEXITED(status))
            return WEXITSTATUS(status);
        return 1;
    }

    /* Child — container side. */
    if (pipe_os)
        close(sock_pair[0]);  /* close parent's end */

    /* Unshare namespaces.  Use CLONE_NEWUSER to avoid needing root. */
    uid_t orig_uid = getuid();
    gid_t orig_gid = getgid();

    int ns_flags = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWIPC;
    if (isolate_net)
        ns_flags |= CLONE_NEWNET;

    if (unshare(ns_flags) != 0) {
        fprintf(stderr, "ldx-container: unshare failed: %s\n", strerror(errno));
        fprintf(stderr, "  (may need: sysctl kernel.unprivileged_userns_clone=1)\n");
        _exit(1);
    }

    /* Map our UID/GID to root inside the user namespace.
     * This gives us CAP_SYS_ADMIN inside the namespace for mount ops. */
    {
        char map[64];
        FILE *f;

        /* Deny setgroups first (required before writing gid_map). */
        f = fopen("/proc/self/setgroups", "w");
        if (f) { fprintf(f, "deny"); fclose(f); }

        snprintf(map, sizeof(map), "0 %d 1\n", orig_uid);
        f = fopen("/proc/self/uid_map", "w");
        if (f) { fprintf(f, "%s", map); fclose(f); }

        snprintf(map, sizeof(map), "0 %d 1\n", orig_gid);
        f = fopen("/proc/self/gid_map", "w");
        if (f) { fprintf(f, "%s", map); fclose(f); }
    }

    /* After CLONE_NEWPID, the next fork's child will be PID 1. */
    pid_t init = fork();
    if (init < 0) {
        perror("ldx-container: fork (init)");
        _exit(1);
    }

    if (init > 0) {
        /* Intermediate process — wait for PID 1 child. */
        int status;
        waitpid(init, &status, 0);
        _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
    }

    /* We are now PID 1 in the new PID namespace. */

    /* Set up rootfs. */
    char rootfs[] = "/tmp/ldx_root_XXXXXX";
    if (!mkdtemp(rootfs)) {
        perror("ldx-container: mkdtemp");
        _exit(1);
    }

    /* Find libldx_syscall.so. */
    char libpath[PATH_MAX] = {};
    {
        /* Look relative to /proc/self/exe → ldx script's dir. */
        char exe[PATH_MAX];
        ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
        if (n > 0) {
            exe[n] = '\0';
            char *slash = strrchr(exe, '/');
            if (slash) {
                *slash = '\0';
                snprintf(libpath, sizeof(libpath), "%s/gen/libldx_syscall.so", exe);
                if (access(libpath, F_OK) != 0)
                    libpath[0] = '\0';
            }
        }
    }

    /* Make rootfs a mount point. */
    mount(rootfs, rootfs, NULL, MS_BIND | MS_REC, NULL);

    if (setup_rootfs(rootfs, binary, libpath[0] ? libpath : NULL) != 0) {
        fprintf(stderr, "ldx-container: rootfs setup failed\n");
        _exit(1);
    }

    if (do_pivot_root(rootfs) != 0) {
        fprintf(stderr, "ldx-container: pivot_root failed\n");
        _exit(1);
    }

    /* Set hostname. */
    sethostname("ldx-container", 13);

    /* Set up environment. */
    if (pipe_os && libpath[0]) {
        setenv("LD_PRELOAD", libpath, 1);
    }

    /* Pass the socket fd to the child via environment. */
    if (pipe_os) {
        char fd_str[16];
        snprintf(fd_str, sizeof(fd_str), "%d", sock_pair[1]);
        setenv("LDX_PIPE_FD", fd_str, 1);
    }

    /* Resolve binary path in new root. */
    char new_binary[PATH_MAX];
    char real_binary[PATH_MAX];
    /* The binary was bind-mounted at its original absolute path. */
    if (realpath(binary, real_binary) == NULL)
        strncpy(real_binary, binary, sizeof(real_binary) - 1);
    strncpy(new_binary, real_binary, sizeof(new_binary) - 1);

    fprintf(stderr, "ldx-container: exec %s (PID %d)\n", new_binary, getpid());

    execv(new_binary, argv);
    fprintf(stderr, "ldx-container: exec failed: %s\n", strerror(errno));
    _exit(1);
}
