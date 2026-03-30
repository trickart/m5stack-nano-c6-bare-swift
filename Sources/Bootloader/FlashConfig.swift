// Flash SPI clock configuration for ESP32-C6.
//
// The ROM bootloader leaves flash at a default low speed. We need to
// configure it for 80MHz DIO mode to match the app image settings.
// This matches what ESP-IDF's bootloader_hardware_init() does.

import _Volatile

// PCR (Peripheral Clock Register) base = 0x60096000
let PCR_MSPI_CLK_CONF_REG: UInt32 = 0x6009_601C

// PCR_MSPI_FAST_HS_DIV_NUM field: bits [15:8]
let MSPI_FAST_HS_DIV_NUM_S: UInt32 = 8
let MSPI_FAST_HS_DIV_NUM_M: UInt32 = 0xFF << 8

// SPI_MEM_CLOCK_REG: base + 0x14
// For freqdiv=1 (80MHz): set CLK_EQU_SYSCLK (bit 31), clear divider fields
private let SPI_MEM_CLK_EQU_SYSCLK: UInt32 = 1 << 31

/// Configure SPI clock divider for the given SPI peripheral.
private func configureSpiClock(_ spi: UInt32, freqdiv: UInt32) {
    let clockReg: UInt32 = 0x6000_2014 + spi * 0x1000
    if freqdiv == 1 {
        regStore(clockReg, SPI_MEM_CLK_EQU_SYSCLK)
    } else {
        let n = freqdiv - 1
        let h = (freqdiv - 1) / 2
        let l = freqdiv - 1
        regStore(clockReg, (n << 16) | (h << 8) | l)
    }
}

// SPI_MEM_CTRL_REG read mode bits (base + 0x08)
private let SPI_MEM_FREAD_QIO: UInt32  = 1 << 24
private let SPI_MEM_FREAD_DIO: UInt32  = 1 << 23
private let SPI_MEM_FASTRD_MODE: UInt32 = 1 << 13

// SPI_MEM_USR_DUMMY_CYCLELEN field: bits [5:0] in USER1_REG (base + 0x1C)
private let SPI_MEM_USR_DUMMY_CYCLELEN_M: UInt32 = 0x3F

/// Fix dummy cycle length for the given SPI peripheral at the specified clock divider.
/// When CLK_EQU_SYSCLK (freqdiv=1), the SPI clock matches the system clock,
/// so fewer dummy cycles are needed. The ROM function applies a correction of -2.
private func fixDummyCycles(_ spi: UInt32, freqdiv: UInt32) {
    let base: UInt32 = 0x6000_2000 + spi * 0x1000
    let ctrl = regLoad(base + 0x08)

    // Determine base dummy cycles from flash read mode (from ESP-IDF spi_flash.h)
    let baseDummy: Int32
    if ctrl & SPI_MEM_FREAD_QIO != 0 {
        baseDummy = 5   // SPI0_R_QIO_DUMMY_CYCLELEN
    } else if ctrl & SPI_MEM_FREAD_DIO != 0 {
        baseDummy = 3   // SPI0_R_DIO_DUMMY_CYCLELEN
    } else if ctrl & SPI_MEM_FASTRD_MODE != 0 {
        baseDummy = 7   // SPI0_R_FAST_DUMMY_CYCLELEN
    } else {
        return  // Slow read mode, no dummy cycles needed
    }

    // At full speed (freqdiv=1, CLK_EQU_SYSCLK), correction is -2
    let correction: Int32 = (freqdiv == 1) ? -2 : 0
    let dummyCycles = UInt32(baseDummy + correction)

    let user1 = regLoad(base + 0x1C)
    regStore(base + 0x1C, (user1 & ~SPI_MEM_USR_DUMMY_CYCLELEN_M) | (dummyCycles & SPI_MEM_USR_DUMMY_CYCLELEN_M))
}

/// Configure flash SPI for 80MHz operation.
/// Equivalent to ESP-IDF's bootloader_hardware_init() flash clock setup.
func configureFlashSPI() {
    // Set MSPI_FAST high-speed divider to 6 (divider value = 5 + 1)
    // clk_ll_mspi_fast_set_hs_divider(6) → writes (6-1)=5 to div_num field
    let conf = regLoad(PCR_MSPI_CLK_CONF_REG)
    regStore(PCR_MSPI_CLK_CONF_REG, (conf & ~MSPI_FAST_HS_DIV_NUM_M) | (5 << MSPI_FAST_HS_DIV_NUM_S))

    // Configure SPI0 (cache controller) and SPI1 (flash controller) for 80MHz
    configureSpiClock(0, freqdiv: 1)  // SPI0 (cache)
    configureSpiClock(1, freqdiv: 1)  // SPI1 (flash)

    // Fix dummy cycle length for 80MHz operation
    fixDummyCycles(0, freqdiv: 1)     // SPI0
    fixDummyCycles(1, freqdiv: 1)     // SPI1

    // Configure SPI1 for DIO flash reads (must be after fixDummyCycles)
    configureSpiReadMode()
}
