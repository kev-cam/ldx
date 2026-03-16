/*
 * ldx-container — CLI entry point for container mode.
 *
 * Usage: ldx-container [--pipe-os] [--net] -- command [args...]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>

extern int ldx_container_run(int argc, char **argv, int pipe_os, int isolate_net);

int main(int argc, char **argv)
{
    int pipe_os = 0;
    int isolate_net = 0;
    int cmd_start = 1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--pipe-os") == 0) {
            pipe_os = 1;
            cmd_start = i + 1;
        } else if (strcmp(argv[i], "--net") == 0) {
            isolate_net = 1;
            cmd_start = i + 1;
        } else if (strcmp(argv[i], "--") == 0) {
            cmd_start = i + 1;
            break;
        } else {
            cmd_start = i;
            break;
        }
    }

    if (cmd_start >= argc) {
        fprintf(stderr, "Usage: ldx-container [--pipe-os] [--net] -- command [args...]\n");
        return 1;
    }

    return ldx_container_run(argc - cmd_start, &argv[cmd_start], pipe_os, isolate_net);
}
