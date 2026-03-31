private let unlockKey: UInt32 = 0x50D8_3AA1

/// Disable a MWDT (Main Watchdog Timer) given the TIMG base address.
/// ESP32-C6 MWDT config registers require conf_update_en (bit 22) to apply changes.
private func disableMWDT(_ base: UInt32) {
    regStore(base + 0x64, unlockKey)          // Unlock WPROTECT
    var cfg = regLoad(base + 0x48)
    cfg &= ~(UInt32(1) << 31)                // Clear wdt_en
    cfg &= ~(UInt32(1) << 14)                // Clear flashboot_mod_en
    // Clear all stages (stg0-stg3) to prevent any timeout action
    cfg &= ~(0x3 << 29)                      // Clear stg0 (bits 30:29)
    cfg &= ~(0x3 << 27)                      // Clear stg1 (bits 28:27)
    cfg &= ~(0x3 << 25)                      // Clear stg2 (bits 26:25)
    cfg &= ~(0x3 << 23)                      // Clear stg3 (bits 24:23)
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
    cfg &= ~(UInt32(1) << 12)                // Clear flashboot_mod_en
    // Clear all stages (stg0-stg3) to prevent any timeout action
    cfg &= ~(0x7 << 28)                      // Clear stg0 (bits 30:28)
    cfg &= ~(0x7 << 25)                      // Clear stg1 (bits 27:25)
    cfg &= ~(0x7 << 22)                      // Clear stg2 (bits 24:22)
    cfg &= ~(0x7 << 19)                      // Clear stg3 (bits 21:19)
    regStore(base, cfg)
    regStore(base + 0x18, 0)                  // Re-lock WPROTECT
}

/// Disable Super Watchdog (SWD).
/// ESP32-C6 SWD uses the same unlock key as the WDT (0x50D83AA1).
private func disableSWD() {
    regStore(0x600B_1C20, unlockKey)          // Unlock SWD_WPROTECT
    var cfg = regLoad(0x600B_1C1C)            // Read SWD_CONFIG
    cfg |= (1 << 18)                          // Set swd_auto_feed_en
    regStore(0x600B_1C1C, cfg)                // Write SWD_CONFIG
    regStore(0x600B_1C20, 0)                  // Re-lock SWD_WPROTECT
}

/// Disable all watchdog timers to prevent chip reset.
func disableWatchdogs() {
    disableMWDT(0x6000_8000)                  // TIMG0
    disableMWDT(0x6000_9000)                  // TIMG1
    disableRWDT()
    disableSWD()
}
