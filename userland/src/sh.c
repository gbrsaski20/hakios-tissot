/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 Minimal Shell
 *
 * A tiny shell for the open user space. It provides basic
 * command execution and is used as the default login shell.
 *
 * This is NOT a full POSIX shell — it's a minimal interactive
 * shell for the research bench.
 */

#include <sys/types.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define SHELL_PROMPT "hakios# "
#define MAX_LINE 256
#define MAX_ARGS 16

/* Raw syscall wrapper (since we don't have a full libc) */
static long
hakios_syscall(int num, ...)
{
    /* On x86_64, syscalls use the syscall instruction */
    /* This is a simplified version; a real one uses inline asm */
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
        ; /* Should never reach */
}

static int
hakios_wait(int *status)
{
    return (int)hakios_syscall(SYS_wait4, -1, status, 0, NULL);
}

static int
hakios_chdir(const char *path)
{
    return (int)hakios_syscall(SYS_chdir, path);
}

static int
hakios_getcwd(char *buf, size_t size)
{
    return (int)hakios_syscall(SYS___getcwd, buf, size);
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

static int
hakios_strncmp(const char *a, const char *b, int n)
{
    while (n > 0 && *a && *b) {
        if (*a != *b)
            return *a - *b;
        a++;
        b++;
        n--;
    }
    return n == 0 ? 0 : *a - *b;
}

static void
hakios_strcpy(char *dst, const char *src)
{
    while ((*dst++ = *src++))
        ;
}

/* ============================================================================
 * Built-in commands
 * ============================================================================
 */

static int
cmd_echo(int argc, char *argv[])
{
    for (int i = 1; i < argc; i++) {
        hakios_write(1, argv[i], hakios_strlen(argv[i]));
        if (i < argc - 1)
            hakios_write(1, " ", 1);
    }
    hakios_write(1, "\n", 1);
    return 0;
}

static int
cmd_cd(int argc, char *argv[])
{
    if (argc < 2) {
        hakios_chdir("/");
    } else {
        if (hakios_chdir(argv[1]) < 0) {
            hakios_write(1, "cd: no such directory\n", 22);
            return 1;
        }
    }
    return 0;
}

static int
cmd_pwd(int argc, char *argv[])
{
    char buf[256];
    if (hakios_getcwd(buf, sizeof(buf)) >= 0) {
        hakios_write(1, buf, hakios_strlen(buf));
        hakios_write(1, "\n", 1);
    }
    return 0;
}

static int
cmd_exit(int argc, char *argv[])
{
    int status = 0;
    if (argc > 1)
        status = atoi(argv[1]);
    hakios_exit(status);
    return 0; /* unreachable */
}

static int
cmd_help(int argc, char *argv[])
{
    const char *help =
        "HakiOS-x86 Minimal Shell\n"
        "Built-in commands:\n"
        "  echo [args...]  Print arguments\n"
        "  cd [dir]        Change directory\n"
        "  pwd             Print working directory\n"
        "  exit [status]   Exit shell\n"
        "  help            Show this help\n"
        "  ls [dir]        List directory\n"
        "  cat [file]      Print file contents\n"
        "  uname           Print system info\n"
        "  reboot          Reboot system\n"
        "\n";
    hakios_write(1, help, hakios_strlen(help));
    return 0;
}

static int
cmd_uname(int argc, char *argv[])
{
    const char *info = "HakiOS-x86\nKernel: XNU x86_64\n";
    hakios_write(1, info, hakios_strlen(info));
    return 0;
}

static int
cmd_reboot(int argc, char *argv[])
{
    hakios_syscall(SYS_reboot, 0, 0);
    return 0;
}

static int
cmd_ls(int argc, char *argv[])
{
    /* Simplified: just print a placeholder */
    const char *msg = "(directory listing not implemented in minimal shell)\n";
    hakios_write(1, msg, hakios_strlen(msg));
    return 0;
}

static int
cmd_cat(int argc, char *argv[])
{
    if (argc < 2) {
        hakios_write(1, "cat: missing file argument\n", 27);
        return 1;
    }

    int fd = hakios_open(argv[1], 0, 0);
    if (fd < 0) {
        hakios_write(1, "cat: cannot open file\n", 22);
        return 1;
    }

    char buf[1024];
    int n;
    while ((n = hakios_read(fd, buf, sizeof(buf))) > 0) {
        hakios_write(1, buf, n);
    }

    hakios_close(fd);
    return 0;
}

/* ============================================================================
 * Command dispatch
 * ============================================================================
 */

typedef int (*cmd_func_t)(int, char *[]);

typedef struct {
    const char *name;
    cmd_func_t func;
} cmd_entry_t;

static cmd_entry_t builtins[] = {
    {"echo", cmd_echo},
    {"cd", cmd_cd},
    {"pwd", cmd_pwd},
    {"exit", cmd_exit},
    {"help", cmd_help},
    {"uname", cmd_uname},
    {"reboot", cmd_reboot},
    {"ls", cmd_ls},
    {"cat", cmd_cat},
    {NULL, NULL}
};

static int
run_builtin(int argc, char *argv[])
{
    for (int i = 0; builtins[i].name; i++) {
        if (hakios_strcmp(argv[0], builtins[i].name) == 0) {
            return builtins[i].func(argc, argv);
        }
    }
    return -1; /* Not a builtin */
}

static int
run_external(int argc, char *argv[])
{
    int pid = hakios_fork();
    if (pid < 0) {
        hakios_write(1, "fork failed\n", 12);
        return 1;
    }

    if (pid == 0) {
        /* Child */
        /* Try to exec the command */
        char path[256];

        /* Try /bin/command */
        hakios_strcpy(path, "/bin/");
        hakios_strcpy(path + 5, argv[0]);
        hakios_execve(path, argv, NULL);

        /* Try /sbin/command */
        hakios_strcpy(path, "/sbin/");
        hakios_strcpy(path + 6, argv[0]);
        hakios_execve(path, argv, NULL);

        /* Try /usr/bin/command */
        hakios_strcpy(path, "/usr/bin/");
        hakios_strcpy(path + 9, argv[0]);
        hakios_execve(path, argv, NULL);

        /* Not found */
        hakios_write(1, argv[0], hakios_strlen(argv[0]));
        hakios_write(1, ": command not found\n", 20);
        hakios_exit(127);
    }

    /* Parent: wait for child */
    int status;
    hakios_wait(&status);
    return status;
}

/* ============================================================================
 * Line parsing
 * ============================================================================
 */

static int
parse_line(char *line, char *argv[], int max_args)
{
    int argc = 0;
    char *p = line;

    while (*p && argc < max_args) {
        /* Skip whitespace */
        while (*p == ' ' || *p == '\t' || *p == '\n')
            p++;
        if (!*p)
            break;

        /* Start of argument */
        argv[argc++] = p;

        /* Find end of argument */
        while (*p && *p != ' ' && *p != '\t' && *p != '\n')
            p++;

        /* Null-terminate */
        if (*p) {
            *p = '\0';
            p++;
        }
    }

    return argc;
}

/* ============================================================================
 * Main loop
 * ============================================================================
 */

int
main(int argc, char *argv[], char *envp[])
{
    char line[MAX_LINE];
    char *args[MAX_ARGS];
    int n;

    /* Print welcome */
    const char *welcome =
        "\n"
        "  _    _    _  _  ___  ____   ____\n"
        " | |  | |  / \\| |/ _ \/ ___| / ___|\n"
        " | |__| | / _ \\ | | | \\___ \\| |\n"
        " |  __  |/ ___ \\| |_| |___) | |___\n"
        " |_|  |_/_/   \\_\\___/|____/ \\____|\n"
        "\n"
        "  x86_64 | XNU kernel | HakiOS-x86\n"
        "\n"
        "Type 'help' for available commands.\n"
        "\n";
    hakios_write(1, welcome, hakios_strlen(welcome));

    while (1) {
        /* Print prompt */
        hakios_write(1, SHELL_PROMPT, hakios_strlen(SHELL_PROMPT));

        /* Read line */
        n = hakios_read(0, line, sizeof(line) - 1);
        if (n <= 0)
            break;

        line[n] = '\0';

        /* Parse */
        int arg_count = parse_line(line, args, MAX_ARGS);
        if (arg_count == 0)
            continue;

        /* Run builtin or external */
        int result = run_builtin(arg_count, args);
        if (result < 0) {
            result = run_external(arg_count, args);
        }
    }

    return 0;
}
