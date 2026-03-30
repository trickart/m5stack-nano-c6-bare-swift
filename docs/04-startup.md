# Task 4: Startup Code (Pure Swift)

## Overview

ESP32-C6 startup implemented in **Pure Swift without any C or assembly**.

## Entry Point: `@main`

```swift
@main
struct Application {
    static func main() {
        disableWatchdogs()  // Highest priority
        // ... application logic
    }
}
```

Same `@main` pattern as [pico-bare-swift](https://github.com/kishikawakatsumi/pico-bare-swift).
SwiftPM's `executableTarget` generates the `main` symbol, which is set as the entry point via `-Xlinker -e -Xlinker main` in toolset.json.

## Why C/Assembly Is Not Needed

The 2nd stage bootloader (written in Swift, `Sources/Bootloader/`) completes the following before jumping to the app entry point:
1. Sets the **stack pointer (SP)**
2. **Copies** IRAM segments from Flash to RAM
3. Configures Flash MMU mapping

## Boot Sequence

```
ROM Bootloader
  → 2nd Stage Bootloader (Swift, Sources/Bootloader/)
    → disableWatchdogs, SP setup, segment loading, Flash MMU configuration
      → main() [@main Application.main()]
        → disableWatchdogs()  ← Disable all WDTs (highest priority)
        → GPIO initialization
        → Main loop
```

## Watchdog Timer Disabling

The bootloader hands control to the app with watchdog timers enabled.
In a bare-metal environment, there is no code to feed the watchdogs, so the chip resets after a few seconds.
When outputting via USB Serial JTAG, the reset disconnects the USB connection, causing monitors like `screen` to terminate.

### Watchdogs That Need to Be Disabled

ESP32-C6 has 4 watchdogs:

| WDT | Base Address | Type |
|-----|-------------|------|
| TIMG0 MWDT | `0x6000_8000` | Main Watchdog Timer (Timer Group 0) |
| TIMG1 MWDT | `0x6000_9000` | Main Watchdog Timer (Timer Group 1) |
| LP_WDT (RWDT) | `0x600B_1C00` | RTC Watchdog (low-power domain) |
| SWD | `0x600B_1C20` | Super Watchdog |

### Register Access

Since swift-mmio does not have register definitions for TIMG/LP_WDT/SWD, direct access is done via `VolatileMappedRegister<UInt32>` (from the `_Volatile` module).

```swift
import _Volatile

@inline(__always)
private func regLoad(_ address: UInt32) -> UInt32 {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
}

@inline(__always)
private func regStore(_ address: UInt32, _ value: UInt32) {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
}
```

Using `UnsafePointer.pointee` risks the compiler optimizing away the register access. `VolatileMappedRegister` guarantees volatile semantics.

**Note**: `.enableExperimentalFeature("Volatile")` is required in `Package.swift`.

### MWDT (TIMG0 / TIMG1)

Each watchdog register is write-protected and requires the unlock key `0x50D8_3AA1` to be written before modification.

| Offset | Register | Purpose |
|--------|----------|---------|
| `0x48` | `WDTCONFIG0` | bit 31: `wdt_en`, bit 22: `conf_update_en`, bit 14: `flashboot_mod_en` |
| `0x64` | `WDTWPROTECT` | Write protection (unlocked by writing the key) |

Config registers are updated asynchronously — `conf_update_en` (bit 22) must be set after modification.

```swift
private func disableMWDT(_ base: UInt32) {
    regStore(base + 0x64, 0x50D8_3AA1)       // Unlock
    var cfg = regLoad(base + 0x48)
    cfg &= ~(UInt32(1) << 31)                // Clear wdt_en
    cfg &= ~(UInt32(1) << 14)                // Clear flashboot_mod_en
    regStore(base + 0x48, cfg)
    cfg = regLoad(base + 0x48)
    cfg |= (1 << 22)                         // Set conf_update_en
    regStore(base + 0x48, cfg)
    regStore(base + 0x64, 0)                 // Re-lock
}
```

### LP_WDT (RTC Watchdog)

| Offset | Register | Purpose |
|--------|----------|---------|
| `0x00` | `CONFIG0` | bit 31: `wdt_en`, bit 12: `flashboot_mod_en` |
| `0x14` | `FEED` | Write 1 to feed |
| `0x18` | `WPROTECT` | Write protection |

A feed operation is required before disabling.

### Super Watchdog (SWD)

The SWD registers are located at LP_WDT base + offset. The unlock key is `0x50D8_3AA1` (same as MWDT/RWDT).

| Offset | Register | Purpose |
|--------|----------|---------|
| `0x1C` | `SWD_CONFIG` | bit 18: `swd_auto_feed_en` |
| `0x20` | `SWD_WPROTECT` | Write protection |

SWD cannot be fully disabled, so `swd_auto_feed_en` is enabled to let the hardware auto-feed.

### References

- [esp32-c6-swift-baremetal](https://github.com/georgik/esp32-c6-swift-baremetal) — C startup + Swift with watchdog disabling
- [pico-bare-swift](https://github.com/kishikawakatsumi/pico-bare-swift) — Example of `VolatileMappedRegister` usage
