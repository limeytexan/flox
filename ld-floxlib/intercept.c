#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <errno.h>

// For access to the in_closure() function.
#include "virtual-sandbox.h"

// Function pointers to hold the original functions
static int (*orig_open)(const char *pathname, int flags, ...) = NULL;
static int (*orig_openat)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*orig_stat)(const char *pathname, struct stat *statbuf) = NULL;
static int (*orig_lstat)(const char *pathname, struct stat *statbuf) = NULL;
static int (*orig_fstat)(int fd, struct stat *statbuf) = NULL;
static int (*orig_newfstatat)(int dirfd, const char *pathname, struct stat *statbuf, int flags) = NULL;

// Load the original functions using dlsym
void load_original_functions() {
    orig_open = dlsym(RTLD_NEXT, "open");
    orig_openat = dlsym(RTLD_NEXT, "openat");
    orig_stat = dlsym(RTLD_NEXT, "stat");
    orig_lstat = dlsym(RTLD_NEXT, "lstat");
    orig_fstat = dlsym(RTLD_NEXT, "fstat");
    orig_newfstatat = dlsym(RTLD_NEXT, "newfstatat");
}

// Interceptor for open
int open(const char *pathname, int flags, ...) {
    if (!orig_open) load_original_functions();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    if (in_closure(pathname)) {
        return orig_open(pathname, flags, mode);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for openat
int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!orig_openat) load_original_functions();
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    if (in_closure(pathname)) {
        return orig_openat(dirfd, pathname, flags, mode);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for stat
int stat(const char *pathname, struct stat *statbuf) {
    if (!orig_stat) load_original_functions();
    if (in_closure(pathname)) {
        return orig_stat(pathname, statbuf);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for lstat
int lstat(const char *pathname, struct stat *statbuf) {
    if (!orig_lstat) load_original_functions();
    if (in_closure(pathname)) {
        return orig_lstat(pathname, statbuf);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for fstat
int fstat(int fd, struct stat *statbuf) {
    if (!orig_fstat) load_original_functions();
    return orig_fstat(fd, statbuf);
}

// Interceptor for newfstatat
int newfstatat(int dirfd, const char *pathname, struct stat *statbuf, int flags) {
    if (!orig_newfstatat) load_original_functions();
    if (in_closure(pathname)) {
        return orig_newfstatat(dirfd, pathname, statbuf, flags);
    } else {
        errno = EACCES;
        return -1;
    }
}
