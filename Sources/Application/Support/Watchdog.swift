private let wdtUnlockKey: UInt32 = 0x50D8_3AA1
private let swdUnlockKey: UInt32 = 0x8F1D_312A

/// Disable a MWDT (Main Watchdog Timer) given the TIMG base address.
private func disableMWDT(_ base: UInt32) {
    regStore(base + 0x64, wdtUnlockKey)
    var cfg = regLoad(base + 0x48)
    cfg &= ~(UInt32(1) << 31)                // Clear wdt_en
    cfg &= ~(UInt32(1) << 12)                // Clear flashboot_mod_en
    regStore(base + 0x48, cfg)
    regStore(base + 0x64, 0)
}

/// Disable RTC Watchdog (LP_WDT at 0x600B_1C00).
private func disableRWDT() {
    let base: UInt32 = 0x600B_1C00
    regStore(base + 0x18, wdtUnlockKey)
    var cfg = regLoad(base)
    cfg &= ~(UInt32(1) << 31)                // Clear wdt_en
    cfg &= ~(UInt32(1) << 12)                // Clear flashboot_mod_en
    regStore(base, cfg)
    regStore(base + 0x14, 1)                 // Feed
    regStore(base + 0x18, 0)
}

/// Disable Super Watchdog (SWD at 0x600B_1C20).
private func disableSWD() {
    let base: UInt32 = 0x600B_1C20
    regStore(base + 0x0C, swdUnlockKey)
    var cfg = regLoad(base)
    cfg |= (1 << 18)                          // Set swd_auto_feed_en
    regStore(base, cfg)
    regStore(base + 0x0C, 0)
}

/// Disable all watchdog timers to prevent chip reset.
func disableWatchdogs() {
    disableMWDT(0x6000_8000)                  // TIMG0
    disableMWDT(0x6000_9000)                  // TIMG1
    disableRWDT()
    disableSWD()
}
