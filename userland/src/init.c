/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Minimal init
 *
 * Fallback init process. If launchd fails to start, the kernel
 * falls back to /sbin/init. This is a minimal init that just
 * starts a shell.
 */

#include <sys/types.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>

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
hakios_strlen(const char *s)
{
    int len = 0;
    while (s[len])
        len++;
    return len;
}

int
main(int argc, char *argv[], char *envp[])
{
    const char *msg = "HakiOS-x86 init: starting shell...\n";
    hakios_write(1, msg, hakios_strlen(msg));

    char *sh_argv[] = {"sh", NULL};
    hakios_execve("/bin/sh", sh_argv, NULL);

    /* If exec fails */
    const char *err = "init: cannot start shell\n";
    hakios_write(1, err, hakios_strlen(err));

    /* Halt */
    hakios_syscall(SYS_reboot, 0, 0);
    hakios_exit(1);

    return 0;
}
