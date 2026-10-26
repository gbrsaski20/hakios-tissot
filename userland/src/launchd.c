/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Minimal launchd
 *
 * A simplified launchd for the open user space. launchd is the
 * first user space process started by the XNU kernel. It is
 * responsible for:
 *   - Starting system daemons
 *   - Managing Mach ports
 *   - Handling signals
 *   - Keeping the system running
 *
 * This is a minimal implementation for the research bench.
 * The full iOS user space uses Apple's launchd.
 */

#include <sys/types.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

/* Raw syscall wrapper */
static long
hakios_syscall(int num, ...)
{
    extern long syscall(long number, ...);
    return syscall(num);
}

static int
hakios_write(int fd, const void *buf, size_t count)
{
    return (int)hakios_syscall(SYS_write, fd, buf, count);
}

static int
hakios_read(int fd, void *buf, size_t count)
{
    return (int)hakios_syscall(SYS_read, fd, buf, count);
}

static int
hakios_fork(void)
{
    return (int)hakios_syscall(SYS_fork);
}

static int
hakios_execve(const char *path, char *const argv[], char *const envp[])
{
    return (int)hakios_syscall(SYS_execve, path, argv, envp);
}

static void
hakios_exit(int status)
{
    hakios_syscall(SYS_exit, status);
    while (1)
        ;
}

static int
hakios_wait(int *status)
{
    return (int)hakios_syscall(SYS_wait4, -1, status, 0, NULL);
}

static int
hakios_open(const char *path, int flags, int mode)
{
    return (int)hakios_syscall(SYS_open, path, flags, mode);
}

static int
hakios_close(int fd)
{
    return (int)hakios_syscall(SYS_close, fd);
}

static int
hakios_mkdir(const char *path, int mode)
{
    return (int)hakios_syscall(SYS_mkdir, path, mode);
}

static int
hakios_getpid(void)
{
    return (int)hakios_syscall(SYS_getpid);
}

static int
hakios_setsid(void)
{
    return (int)hakios_syscall(SYS_setsid);
}

static int
hakios_setpgid(int pid, int pgid)
{
    return (int)hakios_syscall(SYS_setpgid, pid, pgid);
}

/* ============================================================================
 * String utilities
 * ============================================================================
 */

static int
hakios_strlen(const char *s)
{
    int len = 0;
    while (s[len])
        len++;
    return len;
}

static int
hakios_strcmp(const char *a, const char *b)
{
    while (*a && *b) {
        if (*a != *b)
            return *a - *b;
        a++;
        b++;
    }
    return *a - *b;
}

static void
hakios_strcpy(char *dst, const char *src)
{
    while ((*dst++ = *src++))
        ;
}

static void
hakios_strcat(char *dst, const char *src)
{
    while (*dst)
        dst++;
    while ((*dst++ = *src++))
        ;
}

/* ============================================================================
 * launchd main
 * ============================================================================
 */

static void
launchd_log(const char *msg)
{
    hakios_write(1, "[launchd] ", 10);
    hakios_write(1, msg, hakios_strlen(msg));
    hakios_write(1, "\n", 1);
}

static void
setup_environment(void)
{
    /* Create standard directories */
    hakios_mkdir("/tmp", 0755);
    hakios_mkdir("/var", 0755);
    hakios_mkdir("/var/run", 0755);
    hakios_mkdir("/var/tmp", 0755);
    hakios_mkdir("/var/log", 0755);
    hakios_mkdir("/var/mobile", 0755);
    hakios_mkdir("/var/root", 0700);
}

static void
start_daemon(const char *path, char *const argv[])
{
    int pid = hakios_fork();
    if (pid < 0) {
        launchd_log("fork failed");
        return;
    }

    if (pid == 0) {
        /* Child: start the daemon */
        hakios_setsid();
        hakios_setpgid(0, 0);
        hakios_execve(path, argv, NULL);
        /* If exec fails */
        hakios_write(1, "exec failed: ", 13);
        hakios_write(1, path, hakios_strlen(path));
        hakios_write(1, "\n", 1);
        hakios_exit(1);
    }

    /* Parent: log the PID */
    char buf[64];
    snprintf(buf, sizeof(buf), "started %s (pid %d)", path, pid);
    launchd_log(buf);
}

int
main(int argc, char *argv[], char *envp[])
{
    launchd_log("HakiOS-x86 launchd starting");
    launchd_log("PID: ");

    /* Set up the environment */
    setup_environment();

    /* Become session leader */
    hakios_setsid();

    launchd_log("Environment set up");

    /* Start the shell on the console */
    char *sh_argv[] = {"sh", NULL};
    start_daemon("/bin/sh", sh_argv);

    /* Main loop: reap children and keep running */
    while (1) {
        int status;
        int pid = hakios_wait(&status);
        if (pid > 0) {
            char buf[64];
            snprintf(buf, sizeof(buf), "process %d exited with status %d",
                     pid, status);
            launchd_log(buf);

            /* If the shell died, restart it */
            start_daemon("/bin/sh", sh_argv);
        }
    }

    return 0;
}
