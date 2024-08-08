// Declare version bindings to work with minimum supported GLIBC versions.
#if defined( __aarch64__ )
// aarch64 Linux only goes back to 2.17.
// __asm__( ".symver dlsym,dlsym@GLIBC_2.34" );
__asm__( ".symver __errno_location,__errno_location@GLIBC_2.17" );
__asm__( ".symver fclose,fclose@GLIBC_2.17" );
__asm__( ".symver fgets,fgets@GLIBC_2.17" );
__asm__( ".symver fopen,fopen@GLIBC_2.17" );
__asm__( ".symver __fprintf_chk,__fprintf_chk@GLIBC_2.17" );
__asm__( ".symver fwrite,fwrite@GLIBC_2.17" );
__asm__( ".symver getenv,getenv@GLIBC_2.17" );
__asm__( ".symver getpid,getpid@GLIBC_2.17" );
__asm__( ".symver perror,perror@GLIBC_2.17" );
__asm__( ".symver __snprintf_chk,__snprintf_chk@GLIBC_2.17" );
__asm__( ".symver __stack_chk_fail,__stack_chk_fail@GLIBC_2.17" );
__asm__( ".symver __stack_chk_guard,__stack_chk_guard@GLIBC_2.17" );
__asm__( ".symver stderr,stderr@GLIBC_2.17" );
__asm__( ".symver strchr,strchr@GLIBC_2.17" );
__asm__( ".symver strcmp,strcmp@GLIBC_2.17" );
__asm__( ".symver strcspn,strcspn@GLIBC_2.17" );
__asm__( ".symver strncmp,strncmp@GLIBC_2.17" );
__asm__( ".symver strncpy,strncpy@GLIBC_2.17" );
#elif defined( __x86_64__ )
// x86_64 Linux goes back to 2.2.5.
// __asm__( ".symver dlsym,dlsym@GLIBC_2.2.5" );
__asm__( ".symver __errno_location,__errno_location@GLIBC_2.2.5" );
__asm__( ".symver fclose,fclose@GLIBC_2.2.5" );
__asm__( ".symver fgets,fgets@GLIBC_2.2.5" );
__asm__( ".symver fopen,fopen@GLIBC_2.2.5" );
__asm__( ".symver __fprintf_chk,__fprintf_chk@GLIBC_2.2.5" );
__asm__( ".symver fwrite,fwrite@GLIBC_2.2.5" );
__asm__( ".symver getenv,getenv@GLIBC_2.2.5" );
__asm__( ".symver getpid,getpid@GLIBC_2.2.5" );
__asm__( ".symver perror,perror@GLIBC_2.2.5" );
__asm__( ".symver __snprintf_chk,__snprintf_chk@GLIBC_2.2.5" );
__asm__( ".symver __stack_chk_fail,__stack_chk_fail@GLIBC_2.2.5" );
__asm__( ".symver __stack_chk_guard,__stack_chk_guard@GLIBC_2.2.5" );
__asm__( ".symver stderr,stderr@GLIBC_2.2.5" );
__asm__( ".symver strchr,strchr@GLIBC_2.2.5" );
__asm__( ".symver strcmp,strcmp@GLIBC_2.2.5" );
__asm__( ".symver strcspn,strcspn@GLIBC_2.2.5" );
__asm__( ".symver strncmp,strncmp@GLIBC_2.2.5" );
__asm__( ".symver strncpy,strncpy@GLIBC_2.2.5" );
#else
// Punt .. just go with default symbol bindings and hope for the best.
#endif
