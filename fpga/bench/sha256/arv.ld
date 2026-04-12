/* arv.ld — linker script for ARV SoC bare-metal programs.
 * Code + data at 0x80000000 (on-chip RAM, 4 KB).
 * Stack grows down from top of RAM (0x80001000).
 * I/O registers at 0xF0000000.
 */
MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4K
}
SECTIONS {
    .text : { *(.text .text.*) } > RAM
    .rodata : { *(.rodata .rodata.*) } > RAM
    .data : { *(.data .data.*) } > RAM
    .bss : { *(.bss .bss.* COMMON) } > RAM
    _end = .;
}
