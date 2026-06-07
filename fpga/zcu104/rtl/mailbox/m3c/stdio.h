/* Bare-metal shim. The accel-generated cnt32_sm.c #includes <stdio.h> only for
 * printf() inside its SM_NO_MAIN-excluded main(). The RISC-core build (-nostdlib,
 * -I.) has no libc, so this empty shim satisfies the include; the native golden
 * build (no -I.) still gets the real <stdio.h>. */
