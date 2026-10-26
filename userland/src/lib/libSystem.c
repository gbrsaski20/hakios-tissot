/*
 * Copyright (c) 2026 HakiOS-x86 contributors. All rights reserved.
 *
 * HakiOS-x86 libSystem
 *
 * A minimal implementation of libSystem for the open user space.
 * libSystem is the standard system library on Darwin/macOS/iOS.
 * It contains libc, libm, libpthread, and other system libraries.
 *
 * This is a stub implementation for the research bench.
 */

#include <sys/types.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>

/* ============================================================================
 * Syscall wrappers
 * ============================================================================
 */

long
syscall(int num, ...)
{
    /* On x86_64, syscalls use the syscall instruction */
    /* This is a placeholder; a real implementation uses inline asm */
    /* For now, we return an error */
    return -1;
}

/* ============================================================================
 * String functions
 * ============================================================================
 */

size_t
strlen(const char *s)
{
    size_t len = 0;
    while (s[len])
        len++;
    return len;
}

int
strcmp(const char *a, const char *b)
{
    while (*a && *b) {
        if (*a != *b)
            return *a - *b;
        a++;
        b++;
    }
    return *a - *b;
}

int
strncmp(const char *a, const char *b, size_t n)
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

char *
strcpy(char *dst, const char *src)
{
    char *orig = dst;
    while ((*dst++ = *src++))
        ;
    return orig;
}

char *
strncpy(char *dst, const char *src, size_t n)
{
    char *orig = dst;
    while (n > 0 && (*dst++ = *src++))
        n--;
    if (n > 0) {
        while (--n)
            *dst++ = '\0';
    }
    return orig;
}

char *
strcat(char *dst, const char *src)
{
    char *orig = dst;
    while (*dst)
        dst++;
    while ((*dst++ = *src++))
        ;
    return orig;
}

char *
strchr(const char *s, int c)
{
    while (*s) {
        if (*s == c)
            return (char *)s;
        s++;
    }
    return NULL;
}

char *
strstr(const char *haystack, const char *needle)
{
    if (!*needle)
        return (char *)haystack;

    while (*haystack) {
        const char *h = haystack;
        const char *n = needle;
        while (*h && *n && *h == *n) {
            h++;
            n++;
        }
        if (!*n)
            return (char *)haystack;
        haystack++;
    }
    return NULL;
}

/* ============================================================================
 * Memory functions
 * ============================================================================
 */

void *
memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    while (n--)
        *d++ = *s++;
    return dst;
}

void *
memmove(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;

    if (d < s) {
        while (n--)
            *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--)
            *--d = *--s;
    }
    return dst;
}

void *
memset(void *dst, int c, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    while (n--)
        *d++ = (uint8_t)c;
    return dst;
}

int
memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    while (n--) {
        if (*pa != *pb)
            return *pa - *pb;
        pa++;
        pb++;
    }
    return 0;
}

/* ============================================================================
 * Standard I/O stubs
 * ============================================================================
 */

int
printf(const char *format, ...)
{
    /* Minimal printf: just print the format string */
    /* A real implementation would parse format specifiers */
    /* For now, we use write(1, ...) */
    extern int write(int, const void *, size_t);
    write(1, format, strlen(format));
    return 0;
}

int
snprintf(char *str, size_t size, const char *format, ...)
{
    /* Minimal snprintf: just copy the format string */
    strncpy(str, format, size - 1);
    str[size - 1] = '\0';
    return strlen(str);
}

/* ============================================================================
 * stdlib stubs
 * ============================================================================
 */

int
atoi(const char *str)
{
    int result = 0;
    int sign = 1;

    while (*str == ' ' || *str == '\t')
        str++;

    if (*str == '-') {
        sign = -1;
        str++;
    } else if (*str == '+') {
        str++;
    }

    while (*str >= '0' && *str <= '9') {
        result = result * 10 + (*str - '0');
        str++;
    }

    return result * sign;
}

void *
malloc(size_t size)
{
    /* Placeholder: real implementation uses sbrk/mmap */
    return NULL;
}

void
free(void *ptr)
{
    /* Placeholder */
    (void)ptr;
}

void *
calloc(size_t nmemb, size_t size)
{
    /* Placeholder */
    return NULL;
}

void *
realloc(void *ptr, size_t size)
{
    /* Placeholder */
    return NULL;
}

/* ============================================================================
 * Mach stubs (for XNU compatibility)
 * ============================================================================
 */

/* Mach port stubs */
int
mach_msg(void *msg, int option, int send_size, int rcv_size,
         int rcv_name, int timeout, int notify)
{
    /* Placeholder */
    return -1;
}

int
mach_port_allocate(int task, int right, int *name)
{
    /* Placeholder */
    return -1;
}

int
mach_port_deallocate(int task, int name)
{
    /* Placeholder */
    return -1;
}

/* ============================================================================
 * pthread stubs
 * ============================================================================
 */

int
pthread_create(void *thread, const void *attr,
               void *(*start_routine)(void *), void *arg)
{
    /* Placeholder */
    return -1;
}

int
pthread_join(void *thread, void **retval)
{
    /* Placeholder */
    return -1;
}

void
pthread_exit(void *retval)
{
    /* Placeholder */
}

/* ============================================================================
 * dyld stubs
 * ============================================================================
 */

void *_dyld_get_image_header(int image_index)
{
    return NULL;
}

const char *_dyld_get_image_name(int image_index)
{
    return NULL;
}

/* ============================================================================
 * Constructor
 * ============================================================================
 */

void __attribute__((constructor))
libSystem_init(void)
{
    /* Library initialization */
}
