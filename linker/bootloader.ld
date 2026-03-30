/*
 * ESP32-C6 Bootloader Linker Script
 *
 * All sections placed in IRAM since the bootloader runs before
 * Flash MMU is configured. The ROM bootloader loads all segments
 * into RAM before jumping to the entry point.
 *
 */

MEMORY
{
    /* Place bootloader at top of IRAM to avoid overlap with app's
       IRAM/DRAM region which starts at 0x40800000. */
    iram (RWX) : ORIGIN = 0x40870000, LENGTH = 0x10000   /* 64KB at top of IRAM */
}

SECTIONS
{
    /* Code */
    .text : {
        *(.text .text.*)
        . = ALIGN(4);
    } > iram

    /* Read-only data (placed in IRAM for bootloader) */
    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.swift_modhash)
        . = ALIGN(4);
    } > iram

    /* Initialized data */
    .data : {
        _sdata = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.got .got.*)
        *(.got.plt)
        . = ALIGN(4);
        _edata = .;
    } > iram

    /* Uninitialized data */
    .bss (NOLOAD) : {
        . = ALIGN(4);
        _sbss = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > iram

    /* Stack (4KB, sufficient for bootloader) */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        _stack_end = .;
        . += 0x1000;
        . = ALIGN(16);
        _stack_top = .;
    } > iram

    _heap_start = .;
    _heap_end = ORIGIN(iram) + LENGTH(iram);

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.ARM.*)
        *(.riscv.attributes)
    }
}
