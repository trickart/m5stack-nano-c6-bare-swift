// Flash MMU configuration for ESP32-C6.
//
// The MMU maps 64KB pages of physical flash memory to virtual
// addresses in the 0x42000000 range. Both instruction (IROM) and
// data (DROM) share this address space on ESP32-C6.
//
// Following ESP-IDF's set_cache_and_start_app() sequence:
//   1. Disable cache
//   2. Unmap all MMU entries
//   3. Map app segments
//   4. Enable cache buses (IBUS + DBUS)
//   5. Re-enable cache

import _Volatile

// MMU registers (SPI_MEM0 base = 0x60002000)
let MMU_ITEM_CONTENT: UInt32 = 0x6000_237C
let MMU_ITEM_INDEX: UInt32   = 0x6000_2380

// Cache control registers (EXTMEM base = 0x600C8000)
let EXTMEM_L1_CACHE_CTRL_REG: UInt32 = 0x600C_8004
let L1_CACHE_SHUT_IBUS: UInt32 = 1 << 0
let L1_CACHE_SHUT_DBUS: UInt32 = 1 << 1

// Cache autoload control register
let EXTMEM_L1_CACHE_AUTOLOAD_CTRL_REG: UInt32 = 0x600C_8134
let L1_CACHE_AUTOLOAD_ENA: UInt32  = 1 << 0
let L1_CACHE_AUTOLOAD_DONE: UInt32 = 1 << 1

/// Disable the ICache by shutting down IBUS and DBUS.
/// Returns the autoload state (bit 0) so it can be restored later.
func cacheDisableICache() -> UInt32 {
    let autoloadCtrl = regLoad(EXTMEM_L1_CACHE_AUTOLOAD_CTRL_REG)
    let autoloadWasEnabled = autoloadCtrl & L1_CACHE_AUTOLOAD_ENA

    if autoloadWasEnabled != 0 {
        regStore(EXTMEM_L1_CACHE_AUTOLOAD_CTRL_REG, autoloadCtrl & ~L1_CACHE_AUTOLOAD_ENA)
        while regLoad(EXTMEM_L1_CACHE_AUTOLOAD_CTRL_REG) & L1_CACHE_AUTOLOAD_DONE == 0 {}
    }

    let ctrl = regLoad(EXTMEM_L1_CACHE_CTRL_REG)
    regStore(EXTMEM_L1_CACHE_CTRL_REG, ctrl | L1_CACHE_SHUT_IBUS | L1_CACHE_SHUT_DBUS)

    return autoloadWasEnabled
}

/// Re-enable the ICache with the given autoload flags.
func cacheEnableICache(_ autoload: UInt32) {
    let ctrl = regLoad(EXTMEM_L1_CACHE_CTRL_REG)
    regStore(EXTMEM_L1_CACHE_CTRL_REG, ctrl & ~(L1_CACHE_SHUT_IBUS | L1_CACHE_SHUT_DBUS))

    if autoload & L1_CACHE_AUTOLOAD_ENA != 0 {
        let autoloadCtrl = regLoad(EXTMEM_L1_CACHE_AUTOLOAD_CTRL_REG)
        regStore(EXTMEM_L1_CACHE_AUTOLOAD_CTRL_REG, autoloadCtrl | L1_CACHE_AUTOLOAD_ENA)
    }
}


// MMU constants
let MMU_PAGE_SIZE: UInt32    = 0x10000  // 64KB
let MMU_VALID: UInt32        = 1 << 9   // bit 9 = valid
let MMU_ENTRY_NUM: Int       = 256
let FLASH_VADDR_BASE: UInt32 = 0x4200_0000

/// Write a single MMU table entry.
func mmuSetEntry(_ entryId: UInt32, pageNum: UInt32) {
    regStore(MMU_ITEM_INDEX, entryId)
    regStore(MMU_ITEM_CONTENT, pageNum | MMU_VALID)
}

/// Invalidate a single MMU table entry.
func mmuInvalidateEntry(_ entryId: UInt32) {
    regStore(MMU_ITEM_INDEX, entryId)
    regStore(MMU_ITEM_CONTENT, 0)
}

/// Enable cache buses (IBUS and DBUS) by clearing the shutdown bits.
func enableCacheBuses() {
    let ctrl = regLoad(EXTMEM_L1_CACHE_CTRL_REG)
    regStore(EXTMEM_L1_CACHE_CTRL_REG, ctrl & ~(L1_CACHE_SHUT_IBUS | L1_CACHE_SHUT_DBUS))
}


/// Configure Flash MMU mapping for an app image's flash-mapped segments.
func setupFlashMMU(appFlashOffset: UInt32, segmentCount: UInt8) {
    // Step 1: Disable cache before modifying MMU
    let autoload = cacheDisableICache()

    // Step 2: Invalidate all MMU entries
    for i in 0..<UInt32(MMU_ENTRY_NUM) {
        mmuInvalidateEntry(i)
    }

    // Step 3: Walk through image segments and map flash-mapped ones
    var fileOffset: UInt32 = appFlashOffset + 24  // skip 24-byte image header

    for _ in 0..<segmentCount {
        let loadAddr = readFlashUInt32(at: fileOffset)
        let dataLen  = readFlashUInt32(at: fileOffset + 4)
        let dataStart = fileOffset + 8

        // Flash-mapped segment (virtual address in 0x42000000 range)
        if loadAddr >= FLASH_VADDR_BASE && loadAddr < FLASH_VADDR_BASE + UInt32(MMU_ENTRY_NUM) * MMU_PAGE_SIZE {
            let vAddrStart = loadAddr
            let vAddrEnd = loadAddr + dataLen
            let flashDataAddr = dataStart

            let vOffset = vAddrStart & (MMU_PAGE_SIZE - 1)
            let fOffset = flashDataAddr & (MMU_PAGE_SIZE - 1)

            var vPage: UInt32
            var pPage: UInt32
            let vPageEnd: UInt32

            if vOffset == fOffset {
                vPage = (vAddrStart - vOffset - FLASH_VADDR_BASE) / MMU_PAGE_SIZE
                pPage = (flashDataAddr - fOffset) / MMU_PAGE_SIZE
                vPageEnd = ((vAddrEnd - FLASH_VADDR_BASE) + MMU_PAGE_SIZE - 1) / MMU_PAGE_SIZE
            } else {
                vPage = (vAddrStart - FLASH_VADDR_BASE) / MMU_PAGE_SIZE
                pPage = flashDataAddr / MMU_PAGE_SIZE
                vPageEnd = ((vAddrEnd - FLASH_VADDR_BASE) + MMU_PAGE_SIZE - 1) / MMU_PAGE_SIZE
            }

            while vPage < vPageEnd {
                mmuSetEntry(vPage, pageNum: pPage)
                vPage += 1
                pPage += 1
            }
        }

        fileOffset = dataStart + dataLen
    }

    // Step 4: Enable cache buses (IBUS + DBUS)
    enableCacheBuses()

    // Step 5: Re-enable cache
    cacheEnableICache(autoload)
}
