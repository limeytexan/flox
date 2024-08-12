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

// Perform various initialization, which includes loading the original
// glibc functions to be wrapped using dlsym().
void load_original_functions() {
    // Debug sandbox library with FLOX_DEBUG_SANDBOX=1.
    sandbox_debug = ( getenv( "FLOX_DEBUG_SANDBOX" ) != NULL );
    // Derive audit level from FLOX_VIRTUAL_SANDBOX environment variable.
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
    // Declare new functions to be intercepted here, then add stub
    // functions below.
    orig_open = dlsym(RTLD_NEXT, "open");
    orig_openat = dlsym(RTLD_NEXT, "openat");
    orig_stat = dlsym(RTLD_NEXT, "stat");
    orig_lstat = dlsym(RTLD_NEXT, "lstat");
    orig_fstat = dlsym(RTLD_NEXT, "fstat");
    orig_newfstatat = dlsym(RTLD_NEXT, "newfstatat");
}

bool check_argv0_path() {
    static char argv0_path[PATH_MAX];
    // Identify the argv[0] realpath from /proc and flag if it's
    // not in the closure.
    // TODO: find way to detect changes in /proc/self/exe rather than
    //       running realpath() on every path access.
    if (realpath( "/proc/self/exe", argv0_path ) == NULL)
      {
        fprintf( stderr,
                 "ERROR: check_argv0_path() realpath() failed\n" );
        // If realpath() failed to set the realpath then explicitly
        // ensure our buffer returns an empty string.
        argv0_path[0] = '\0';
      }
    _debug( "sandbox_level=%d, argv0=%s", sandbox_level, argv0_path );
    // The use of certain paths like `/usr/bin/env` path is ubiquitous and
    // hardcoded to an extent that we cannot really expect developers to
    // replace it in code, so we instead allow exceptions for a limited
    // number of these paths.
    // simply let it be an allowed exception.
    //
    // Once requested by way of the la_version() call, we know that all
    // libraries requested by this PID are similarly linked from /usr/bin/env
    // so we can simply give all lookups a free pass.
    if (
        strcmp(argv0_path, "/usr/bin/env") == 0 ||
        strcmp(argv0_path, "/bin/sh") == 0 ||
        strcmp(argv0_path, "/usr/bin/dash") == 0
    ) return true;
}

// Some paths are derived from allowed basenames.
bool check_allowed_basenames( const char * pathname ) {
    if ( strncmp(pathname, "/dev/", 5) == 0 ) return true;
    if ( strncmp(pathname, "/sys/", 5) == 0 ) return true;
    if ( strncmp(pathname, "/proc/", 6) == 0 ) return true;
    // TODO: evaluate FLOX_SRC_DIR just once
    const char *flox_src_dir = getenv("FLOX_SRC_DIR");
    if (flox_src_dir) {
	if ( strncmp(pathname, flox_src_dir, strlen(flox_src_dir)) == 0 &&
	  ( pathname[strlen(flox_src_dir)] == '/' || pathname[strlen(flox_src_dir)] == '\0' )
	) {
	    return true;
	}
    }
    return false;
}

// Check if path access represents something that may not be reproducible
// on another machine. Any path within the environment's closure is fine,
// but there are also other specific paths and basenames accessed during a
// build that we can similarly rely to be present on any machine.
//
// The challenge here is that some path accesses are discrete while others
// are modal, implying a different handling for subsequent path accesses.
// One example of this is the use of `/usr/bin/env`, which is ubiquitous
// and hardcoded to an extent that we cannot really expect users to replace
// references to it in code, so when invoking this path we suspend all
// further path checking until argv0 is updated to a new path.
bool check_path( const char * pathname ) {
    if (sandbox_level < 0) load_original_functions();
    if (sandbox_level == 0 || in_closure(pathname)) return true;
    if (check_argv0_path()) return true;
    if (check_allowed_basenames(pathname)) return true;
    if (sandbox_level == 1) {
        _warn( "%s is not in the closure", pathname );
        return true;
    } else {
        _error( "%s is not in the closure", pathname );
        return false;
    }
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
    if (check_path(pathname)) {
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
    if (check_path(pathname)) {
        return orig_openat(dirfd, pathname, flags, mode);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for stat
int stat(const char *pathname, struct stat *statbuf) {
    if (!orig_stat) load_original_functions();
    if (check_path(pathname)) {
        return orig_stat(pathname, statbuf);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for lstat
int lstat(const char *pathname, struct stat *statbuf) {
    if (!orig_lstat) load_original_functions();
    if (check_path(pathname)) {
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
    if (check_path(pathname)) {
        return orig_newfstatat(dirfd, pathname, statbuf, flags);
    } else {
        errno = EACCES;
        return -1;
    }
}
