#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <errno.h>

// For access to the in_closure() function.
#include "closure.h"

// Declare version bindings to work with minimum supported GLIBC versions.
#include "glibc-bindings.h"

// Derive audit level from FLOX_VIRTUAL_SANDBOX environment variable.
static int    sandbox_level = -1;
// Debug sandbox library with FLOX_DEBUG_SANDBOX=1.
static int    sandbox_debug = -1;
// Counter for use with _warn_once() macro.
static int    warn_count = 0;

// Function pointers to hold the original functions
static int (*orig_open)(const char *pathname, int flags, ...) = NULL;
static int (*orig_openat)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*orig_stat)(const char *pathname, struct stat *statbuf) = NULL;
static int (*orig_lstat)(const char *pathname, struct stat *statbuf) = NULL;
static int (*orig_fstat)(int fd, struct stat *statbuf) = NULL;
static int (*orig_newfstatat)(int dirfd, const char *pathname, struct stat *statbuf, int flags) = NULL;

// Helper macros for printing debug, warnings, errors.
#define _debug(format, ...) \
  if (sandbox_debug) \
    fprintf(stderr, "DEBUG[%d]: " format "\n", getpid(), __VA_ARGS__)
#define _audit(format, ...) \
  if ( audit_ld_floxlib || sandbox_debug ) \
    fprintf(stderr, "AUDIT[%d]: " format "\n", getpid(), __VA_ARGS__)
#define _warn(format, ...) fprintf(stderr, "WARNING[%d]: " format "\n", getpid(), ##__VA_ARGS__)
#define _warn_once(format, ...) \
  if (sandbox_debug) \
    _warn(format, ##__VA_ARGS__); \
  else if (warn_count++ == 0) \
    _warn(format " (further warnings suppressed)", ##__VA_ARGS__)
#define _error(format, ...) fprintf(stderr, "ERROR[%d]: " format "\n", getpid(), __VA_ARGS__)

// Load the original functions using dlsym
void load_original_functions() {
    if ( sandbox_debug < 0 )
      {
        sandbox_debug = ( getenv( "FLOX_DEBUG_SANDBOX" ) != NULL );
      }
    const char * flox_virtual_sandbox_value = getenv( "FLOX_VIRTUAL_SANDBOX" );
    if (flox_virtual_sandbox_value == NULL ||
       (strcmp(flox_virtual_sandbox_value, "off") == 0)) {
      sandbox_level = 0;
    } else if (strcmp(flox_virtual_sandbox_value, "warn") == 0) {
      sandbox_level = 1;
    } else if (strcmp(flox_virtual_sandbox_value, "enforce") == 0) {
      sandbox_level = 2;
    } else if (strcmp(flox_virtual_sandbox_value, "pure") == 0) {
      // Pure mode is just like enforce, but invoked within the Nix sandbox.
      sandbox_level = 3;
    } else {
      _warn_once( "FLOX_VIRTUAL_SANDBOX must be (off|warn|enforce|pure) ... ignoring" );
      sandbox_level = 0;
    }
    _debug( "sandbox_level=%d", sandbox_level );
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
    if (sandbox_level == 0 || in_closure(pathname)) {
        return orig_open(pathname, flags, mode);
    } else if (sandbox_level == 1) {
        _warn( "%s is not in the closure", pathname );
        return orig_open(pathname, flags, mode);
    } else {
        _error( "%s is not in the closure", pathname );
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
    if (sandbox_level == 0 || in_closure(pathname)) {
        return orig_openat(dirfd, pathname, flags, mode);
    } else if (sandbox_level == 1) {
        _warn( "%s is not in the closure", pathname );
        return orig_openat(dirfd, pathname, flags, mode);
    } else {
        _error( "%s is not in the closure", pathname );
        errno = EACCES;
        return -1;
    }
}

// Interceptor for stat
int stat(const char *pathname, struct stat *statbuf) {
    if (!orig_stat) load_original_functions();
    if (sandbox_level == 0 || in_closure(pathname)) {
        return orig_stat(pathname, statbuf);
    } else if (sandbox_level == 1) {
        _warn( "%s is not in the closure", pathname );
        return orig_stat(pathname, statbuf);
    } else {
        _error( "%s is not in the closure", pathname );
        errno = EACCES;
        return -1;
    }
}

// Interceptor for lstat
int lstat(const char *pathname, struct stat *statbuf) {
    if (!orig_lstat) load_original_functions();
    if (sandbox_level == 0 || in_closure(pathname)) {
        return orig_lstat(pathname, statbuf);
    } else if (sandbox_level == 1) {
        _warn( "%s is not in the closure", pathname );
        return orig_lstat(pathname, statbuf);
    } else {
        _error( "%s is not in the closure", pathname );
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
    if (sandbox_level == 0 || in_closure(pathname)) {
        return orig_newfstatat(dirfd, pathname, statbuf, flags);
    } else if (sandbox_level == 1) {
        _warn( "%s is not in the closure", pathname );
        return orig_newfstatat(dirfd, pathname, statbuf, flags);
    } else {
        _error( "%s is not in the closure", pathname );
        errno = EACCES;
        return -1;
    }
}
