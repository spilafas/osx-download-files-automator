/*
 * Tiny launcher that lives inside "AI File Renamer.app".
 *
 * launchd starts this binary, and it runs Python as a child process. macOS
 * privacy checks (Full Disk Access) are made against the "responsible"
 * process, which children inherit, so access granted to AI File Renamer.app
 * covers the Python script it runs.
 *
 * Usage: launcher <python> <script> [args...]
 */
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;
static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <python> <script> [args...]\n", argv[0]);
        return 2;
    }
    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);

    int err = posix_spawn(&child, argv[1], NULL, NULL, argv + 1, environ);
    if (err != 0) {
        errno = err;
        perror("posix_spawn");
        return 1;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + WTERMSIG(status);
}
