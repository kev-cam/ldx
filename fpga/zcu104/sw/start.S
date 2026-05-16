// start.S — VexRiscv reset entry. Sets stack and calls main.
.section .text.boot, "ax"
.globl _start
_start:
    la sp, _stack_top
    call main
1:  j 1b
