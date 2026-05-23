/* Minimal startup for VexRiscv */
.section .text
.globl _start
_start:
    la sp, 0x80000800  /* Stack at end of first 2KB */
    call main
1:  j 1b           /* Infinite loop if main returns */
