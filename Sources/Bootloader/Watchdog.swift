// Disable all watchdog timers to prevent resets during boot.
// Same logic as Application/Support/Watchdog.swift but using
// direct volatile access without MMIO dependency.

import _Volatile

@inline(__always)
func regLoad(_ addr: UInt32) -> UInt32 {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(addr)).load()
}

@inline(__always)
func regStore(_ addr: UInt32, _ value: UInt32) {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(addr)).store(value)
}

private let unlockKey: UInt32 = 0x50D8_3AA1

/// Disable a MWDT (Main Watchdog Timer) given the TIMG base address.
/// ESP32-C6 MWDT config registers require conf_update_en (bit 22) to apply changes.
private func disableMWDT(_ base: UInt32) {
    regStore(base + 0x64, unlockKey)      // Unlock WPROTECT
    // Clear wdt_en (bit 31) and flashboot_mod_en (bit 14)
    var cfg = regLoad(base + 0x48)
    cfg &= ~(UInt32(1) << 31)                // Clear wdt_en
    cfg &= ~(UInt32(1) << 14)                // Clear flashboot_mod_en
    regStore(base + 0x48, cfg)
    // Trigger async config update
    cfg = regLoad(base + 0x48)
    cfg |= (1 << 22)                         // Set conf_update_en
    regStore(base + 0x48, cfg)
    regStore(base + 0x64, 0)                  // Re-lock WPROTECT
}

/// Disable RTC Watchdog (LP_WDT at 0x600B_1C00).
/// LP_WDT config registers update immediately (no conf_update_en needed).
private func disableRWDT() {
    let base: UInt32 = 0x600B_1C00
    regStore(base + 0x18, unlockKey)          // Unlock WPROTECT
    regStore(base + 0x14, 1)                  // Feed before disabling
    var cfg = regLoad(base)
    cfg &= ~(UInt32(1) << 31)                // Clear wdt_en
    regStore(base, cfg)
    regStore(base + 0x18, 0)                  // Re-lock WPROTECT
}

/// Disable Super Watchdog (SWD).
/// ESP32-C6 SWD uses the same unlock key as the WDT (0x50D83AA1).
private func disableSWD() {
    regStore(0x600B_1C20, unlockKey)        // Unlock SWD_WPROTECT
    var cfg = regLoad(0x600B_1C1C)             // Read SWD_CONFIG
    cfg |= (1 << 18)                           // Set swd_auto_feed_en
    regStore(0x600B_1C1C, cfg)                 // Write SWD_CONFIG
    regStore(0x600B_1C20, 0)                   // Re-lock SWD_WPROTECT
}

func disableWatchdogs() {
    disableMWDT(0x6000_8000)                   // TIMG0
    disableMWDT(0x6000_9000)                   // TIMG1
    disableRWDT()
    disableSWD()
}
