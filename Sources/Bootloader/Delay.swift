// SYSTIMER-based delay for bootloader.
// SYSTIMER runs at 16 MHz on ESP32-C6 (1 tick = 1/16 µs).

import _Volatile

// SYSTIMER registers (base: 0x6000A000)
let SYSTIMER_UNIT0_OP: UInt32       = 0x6000_A004
let SYSTIMER_UNIT0_VALUE_LO: UInt32 = 0x6000_A044

/// Delay for the specified number of milliseconds using SYSTIMER.
func delayMs(_ ms: UInt32) {
    // Trigger a timer update and wait for it to be ready
    regStore(SYSTIMER_UNIT0_OP, 1 << 30)
    while regLoad(SYSTIMER_UNIT0_OP) & (1 << 29) == 0 {}
    let start = regLoad(SYSTIMER_UNIT0_VALUE_LO)

    // 16 ticks = 1 µs, so 16000 ticks = 1 ms
    let ticks = ms &* 16000
    while true {
        regStore(SYSTIMER_UNIT0_OP, 1 << 30)
        while regLoad(SYSTIMER_UNIT0_OP) & (1 << 29) == 0 {}
        let now = regLoad(SYSTIMER_UNIT0_VALUE_LO)
        if (now &- start) >= ticks { break }
    }
}
