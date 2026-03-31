/* fpga.ld — Linker script for VexRiscv on Cyclone IV GX.
 * RAM at 0x80000000 (32 KB), entry at _start.
 */
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4K
}

SECTIONS {
    .text : { *(.text._start) *(.text*) } > RAM
    .rodata : { *(.rodata*) } > RAM
    .data : { *(.data*) } > RAM
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) } > RAM
    _end = .;
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
