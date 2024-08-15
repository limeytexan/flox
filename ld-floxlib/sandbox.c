/*
 * The Flox "virtual sandbox" warns or aborts when encountering an ELF access
 * from outside the closure of packages implied by $FLOX_ENV. In this regard
 * it can provide the same guarantees at an ELF level provided by the sandbox
 * itself, but at an _advisory_ level, so that developers are informed of
 * missing dependencies without actually breaking anything.
 *
 * The virtual sandbox is enabled with `FLOX_VIRTUAL_SANDBOX=(warn|enforce)`
 * set in the environment, and we do this when wrapping files in the bin
 * directory in the course of performing a manifest build.
 *
 * As with the parsing of FLOX_ENV_LIB_DIRS, it is essential that this parsing
 * of the closure be performant and initialized only once per invocation, so we
 * start by reading closure paths into a btable from $FLOX_ENV/requisites.txt.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <limits.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <errno.h>

// Declare version bindings to work with minimum supported GLIBC versions.
#include "glibc-bindings.h"

// For access to the in_closure() function.
#include "closure.h"

// Derive audit level from FLOX_VIRTUAL_SANDBOX environment variable.
int    sandbox_level = -1;

// Function pointers to hold the original functions
static int (*orig_open)(const char *pathname, int flags, ...) = NULL;
static int (*orig_openat)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*orig_stat)(const char *pathname, struct stat *statbuf) = NULL;
static int (*orig_lstat)(const char *pathname, struct stat *statbuf) = NULL;
static int (*orig_fstat)(int fd, struct stat *statbuf) = NULL;
static int (*orig_newfstatat)(int dirfd, const char *pathname, struct stat *statbuf, int flags) = NULL;

// Helper macros for printing debug, warnings, errors.
static int    debug_sandbox = -1;
static int    warn_count = 0;
#define debug(format, ...) \
  if (debug_sandbox) \
    fprintf(stderr, "SANDBOX DEBUG[%d]: " format "\n", getpid(), __VA_ARGS__)
#define warn(format, ...) fprintf(stderr, "SANDBOX WARNING[%d]: " format "\n", getpid(), ##__VA_ARGS__)
#define warn_once(format, ...) \
  if (debug_sandbox) \
    warn(format, ##__VA_ARGS__); \
  else if (warn_count++ == 0) \
    warn(format " (further warnings suppressed)", ##__VA_ARGS__)
#define _error(format, ...) fprintf(stderr, "SANDBOX ERROR[%d]: " format "\n", getpid(), ##__VA_ARGS__)

// Perform various initialization, which includes loading the original
// glibc functions to be wrapped using dlsym().
void load_original_functions() {

    // Debug sandbox library with FLOX_DEBUG_SANDBOX=1.
    debug_sandbox = ( getenv( "FLOX_DEBUG_SANDBOX" ) != NULL );

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
      warn_once( "FLOX_VIRTUAL_SANDBOX must be (off|warn|enforce|pure) ... ignoring" );
      sandbox_level = 0;
    }
    debug( "sandbox_level=%d", sandbox_level );

    // Declare new functions to be intercepted here, then add stub
    // functions below.
    orig_open = dlsym(RTLD_NEXT, "open");
    orig_openat = dlsym(RTLD_NEXT, "openat");
    orig_stat = dlsym(RTLD_NEXT, "stat");
    orig_lstat = dlsym(RTLD_NEXT, "lstat");
    orig_fstat = dlsym(RTLD_NEXT, "fstat");
    orig_newfstatat = dlsym(RTLD_NEXT, "newfstatat");
}

// Accessor method for determining sandbox_level defined as a
// static int in this file.
int get_sandbox_level() {
    return sandbox_level;
}

bool sandbox_check_argv0() {
    static char argv0_path[PATH_MAX];
    if (sandbox_level < 0) load_original_functions();
    // Identify the argv[0] realpath from /proc and flag if it's
    // not in the closure.
    // TODO: find way to detect changes in /proc/self/exe rather than
    //       running realpath() on every path access.
    if (realpath( "/proc/self/exe", argv0_path ) == NULL)
      {
        _error( "sandbox_check_argv0() realpath() failed\n" );
        // If realpath() failed to set the realpath then explicitly
        // ensure our buffer returns an empty string.
        argv0_path[0] = '\0';
      }
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
    ) {
      debug( "%s is a permitted argv0", argv0_path );
      return true;
    } else {
      debug( "%s is a not permitted argv0", argv0_path );
      return false;
    }
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
            debug( "%s is an allowed basename", pathname );
	    return true;
	}
    }
    debug( "%s is not an allowed basename", pathname );
    return false;
}

// Some absolute paths like "." are always permitted.
bool check_allowed_abspaths( const char * pathname ) {
    if (
        strncmp(pathname, ".", 1) == 0
    ) {
        debug( "%s is an allowed abspath", pathname );
        return true;
    } else {
        debug( "%s is not an allowed abspath", pathname );
        return false;
    }
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
bool sandbox_check_path( const char * pathname ) {
    if (sandbox_level < 0) load_original_functions();
    if (sandbox_level == 0) return true;
    if (in_closure(pathname)) return true;
    if (sandbox_check_argv0()) return true;
    if (check_allowed_basenames(pathname)) return true;
    if (check_allowed_abspaths(pathname)) return true;
    if (sandbox_level == 1) {
        warn( "%s is not in the sandbox", pathname );
        return true;
    } else {
        _error( "%s is not in the sandbox", pathname );
        return false;
    }
}

// Interceptor for open
int open(const char *pathname, int flags, ...) {
    if (!orig_open) load_original_functions();
    debug("open(%s)", pathname);
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    if (sandbox_check_path(pathname)) {
        return orig_open(pathname, flags, mode);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for openat
int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!orig_openat) load_original_functions();
    debug("openat(%s)", pathname);
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, mode_t);
        va_end(args);
    }
    if (sandbox_check_path(pathname)) {
        return orig_openat(dirfd, pathname, flags, mode);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for stat
int stat(const char *pathname, struct stat *statbuf) {
    if (!orig_stat) load_original_functions();
    debug("stat(%s)", pathname);
    if (sandbox_check_path(pathname)) {
        return orig_stat(pathname, statbuf);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for lstat
int lstat(const char *pathname, struct stat *statbuf) {
    if (!orig_lstat) load_original_functions();
    debug("lstat(%s)", pathname);
    if (sandbox_check_path(pathname)) {
        return orig_lstat(pathname, statbuf);
    } else {
        errno = EACCES;
        return -1;
    }
}

// Interceptor for fstat
int fstat(int fd, struct stat *statbuf) {
    if (!orig_fstat) load_original_functions();
    debug("fstat(%d)", fd);
    return orig_fstat(fd, statbuf);
}

// Interceptor for newfstatat
int newfstatat(int dirfd, const char *pathname, struct stat *statbuf, int flags) {
    if (!orig_newfstatat) load_original_functions();
    debug("newfstatat(%s)", pathname);
    if (sandbox_check_path(pathname)) {
        return orig_newfstatat(dirfd, pathname, statbuf, flags);
    } else {
        errno = EACCES;
        return -1;
    }
}
