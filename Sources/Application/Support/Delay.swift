import Registers
import MMIO

/// SYSTIMER runs at 16 MHz (default on ESP32-C6).
/// 1 tick = 1/16 us, so 16 ticks = 1 us.
func delayUs(_ us: UInt32) {
    systimer.unit0_op.write { $0.raw.storage = 1 << 30 }
    while systimer.unit0_op.read().raw.storage & (1 << 29) == 0 {}
    let startLo = systimer.unit0_value_lo.read().raw.storage

    let ticks = us &* 16
    while true {
        systimer.unit0_op.write { $0.raw.storage = 1 << 30 }
        while systimer.unit0_op.read().raw.storage & (1 << 29) == 0 {}
        let nowLo = systimer.unit0_value_lo.read().raw.storage
        if (nowLo &- startLo) >= ticks {
            break
        }
    }
}
