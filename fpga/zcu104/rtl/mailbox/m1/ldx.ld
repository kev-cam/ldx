/* ldx.ld — bare-metal linker for ldx_soc_axi.
 * 4 KB ITCM/DTCM at 0x80000000. Stack at top.
 * I/O at 0xF0000000+. _start must be at 0x80000000 (VexRiscv reset vector).
 */
MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4K
}
ENTRY(_start)
SECTIONS {
    .text 0x80000000 : {
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > RAM
    .rodata : { *(.rodata .rodata.*) } > RAM
    .data   : { *(.data .data.*)   } > RAM
    .bss    : { *(.bss .bss.* COMMON) } > RAM
    _end = .;
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
