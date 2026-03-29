/*
 * ESP32-C6 Linker Script for Bare-Metal Swift
 *
 * The ESP-IDF bootloader (SOC_MMU_DI_VADDR_SHARED) requires exactly
 * 2 flash-mapped segments in the 0x42000000 range (IROM + DROM),
 * plus IRAM segments in the 0x40800000 range.
 *
 * We place .text in IROM and .rodata in DROM (both flash-mapped),
 * and .data/.bss in IRAM (loaded to RAM by bootloader).
 */

MEMORY
{
    iram (RWX) : ORIGIN = 0x40800000, LENGTH = 0x80000
    irom (RX)  : ORIGIN = 0x42000020, LENGTH = 0x200000 - 0x20
    drom (R)   : ORIGIN = 0x42010020, LENGTH = 0x200000 - 0x20
    lp_ram (RW) : ORIGIN = 0x50000000, LENGTH = 0x4000
}

SECTIONS
{
    /* Code in flash-mapped IROM */
    .text : {
        _stext = .;
        *(.text .text.*)
        . = ALIGN(4);
        _etext = .;
    } > irom

    /* Read-only data in flash-mapped DROM */
    .rodata : {
        . = ALIGN(4);
        _srodata = .;
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.swift_modhash)
        . = ALIGN(4);
        _erodata = .;
    } > drom

    /* Initialized data in IRAM (loaded from flash by bootloader) */
    .data : {
        . = ALIGN(4);
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

    /* Reserve stack space in IRAM (NOLOAD so bootloader doesn't need to load it) */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        _stack_end = .;
        . += 0x4000;  /* 16KB stack */
        . = ALIGN(16);
        _stack_top = .;
    } > iram

    . = ALIGN(8);
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
