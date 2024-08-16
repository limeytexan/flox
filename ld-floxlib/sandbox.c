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
void sandbox_init() {

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
}

// Accessor method for determining sandbox_level defined as a
// static int in this file.
int get_sandbox_level() {
    return sandbox_level;
}

bool sandbox_check_argv0() {
    static char argv0_path[PATH_MAX];
    if (sandbox_level < 0) sandbox_init();
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
      return false;
    }
}

// Some paths are derived from allowed basenames.

// Define the maximum number of directories that can be specified in
// the FLOX_SANDBOX_ALLOW_DIRS environment variable. This is a somewhat
// arbitrary limit, but it should be more than enough for most cases.
#define FLOX_SANDBOX_ALLOW_DIRS_MAXENTRIES 256

// Define the maximum length of a directory path in the FLOX_SANDBOX_ALLOW_DIRS
// environment variable. This is also somewhat arbitrary, but it should
// be more than enough for most cases.
#define FLOX_SANDBOX_ALLOW_DIRS_MAXLEN PATH_MAX

static int    allow_dirs_count = -1;
static char   allow_dirs_buf[FLOX_SANDBOX_ALLOW_DIRS_MAXLEN];
static char * allow_dirs[FLOX_SANDBOX_ALLOW_DIRS_MAXENTRIES];
bool check_allowed_basenames( const char * pathname ) {
  // Start by reading the contents of FLOX_ALLOW_SANDBOX_DIRS into array
  if ( allow_dirs_count == -1 )
    {
      // Copy the contents of the FLOX_SANDBOX_ALLOW_DIRS variable into
      // allow_dirs_buf and tokenize the buffer by replacing
      // colons with NULLs as we count the entries, saving pointers
      // to each of the paths in the allow_dirs[] array.
      allow_dirs_count = 0;
      const char * allow_dirs_env
        = getenv( "FLOX_SANDBOX_ALLOW_DIRS" );
      if ( allow_dirs_env != NULL )
        {
          if ( sizeof( allow_dirs_env )
               >= FLOX_SANDBOX_ALLOW_DIRS_MAXLEN )
            {
              _error( "check_allowed_basenames() FLOX_SANDBOX_ALLOW_DIRS is too long, "
                     "truncating to %d characters\n",
                     FLOX_SANDBOX_ALLOW_DIRS_MAXLEN );
            }

          strncpy( allow_dirs_buf,
                   allow_dirs_env,
                   sizeof( allow_dirs_buf ) );


          // Iterate over the space-separated list of paths in the
          // allow_dirs buffer, tokenizing as we go and
          // maintaining a count of the number of entries found.
          char * allow_dir = NULL;
          char * saveptr                = NULL;  // For strtok_r() context

          allow_dir
            = strtok_r( allow_dirs_buf, " ", &saveptr );
          while ( allow_dir != NULL )
            {
              if ( allow_dirs_count
                   >= FLOX_SANDBOX_ALLOW_DIRS_MAXENTRIES )
                {
                  _error( "la_objsearch() "
                          "FLOX_SANDBOX_ALLOW_DIRS has too many entries, "
                          "truncating to the first %d",
                          FLOX_SANDBOX_ALLOW_DIRS_MAXENTRIES );
                  break;
                }
              debug( "la_objsearch() allow_dirs[%d] = %s",
                      allow_dirs_count,
                      allow_dir );
              allow_dirs[allow_dirs_count]
                = allow_dir;
              allow_dir = strtok_r( NULL, " ", &saveptr );
              allow_dirs_count++;
            }
        }

      // Add a few static entries to the end of the list.
      allow_dirs[allow_dirs_count++] = "/tmp";
      allow_dirs[allow_dirs_count++] = "/dev";
      allow_dirs[allow_dirs_count++] = "/sys";
      allow_dirs[allow_dirs_count++] = "/proc";

      const char *flox_src_dir = getenv("FLOX_SRC_DIR");
      if (flox_src_dir) allow_dirs[allow_dirs_count++] = flox_src_dir;
    }

  // Iterate over the allow_dirs list looking for pathname.
  static int i;
  for ( i = 0; i < allow_dirs_count; i++ )
    {
        if ( strncmp(pathname, allow_dirs[i], strlen(allow_dirs[i])) == 0 &&
          ( pathname[strlen(allow_dirs[i])] == '/' || pathname[strlen(allow_dirs[i])] == '\0' )
        ) {
            debug( "%s is an allowed basename", pathname );
            return true;
        }
    }
  return false;
}

// Forward declaration of sandbox_check_path().
bool sandbox_check_path( const char * pathname );

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
    static char real_path[PATH_MAX];
    if (sandbox_level < 0) sandbox_init();
    if (sandbox_level == 0) return true;
    debug( "sandbox_check_path('%s'), sandbox_level=%d", pathname, sandbox_level );
    if (sandbox_check_argv0()) return true;

    // From here on out, operate on realpath. If a file doesn't exist
    // then return true and let ENOENT be the eventual result.
    if (realpath( pathname, real_path ) == NULL) return true;
    if (check_allowed_basenames(real_path)) return true;
    if (in_closure(real_path)) return true;
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
    if (!orig_open) sandbox_init();
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
    if (!orig_openat) sandbox_init();
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
