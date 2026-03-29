# Task 8: Delay & Serial Output Implementation (Without ROM Functions)

## Overview

Microsecond delay using SYSTIMER and direct serial output to USB Serial JTAG, implemented via swift-mmio register operations.

## Delay (SYSTIMER)

### How It Works

SYSTIMER runs at a default 16MHz (1 tick = 1/16 us).
It reads the unit0 counter value and polls until the specified microseconds have elapsed.

### Implementation

```swift
func delayUs(_ us: UInt32) {
    // Trigger unit0 counter value update
    systimer.unit0_op.write { $0.raw.storage = 1 << 30 }
    // Wait until value is valid
    while systimer.unit0_op.read().raw.storage & (1 << 29) == 0 {}
    let startLo = systimer.unit0_value_lo.read().raw.storage

    let ticks = us &* 16  // 16MHz → 16 ticks/us
    while true {
        systimer.unit0_op.write { $0.raw.storage = 1 << 30 }
        while systimer.unit0_op.read().raw.storage & (1 << 29) == 0 {}
        let nowLo = systimer.unit0_value_lo.read().raw.storage
        if (nowLo &- startLo) >= ticks { break }
    }
}
```

### Registers

| Register | Bit | Purpose |
|----------|-----|---------|
| `unit0_op` | bit 30 (W) | Counter value update trigger |
| `unit0_op` | bit 29 (R) | Whether the counter value is valid |
| `unit0_value_lo` | 0..31 (R) | Lower 32 bits of the counter value |

### Notes

- `&*` and `&-` are used for overflow-safe arithmetic
- Only the lower 32 bits are used (wraps around after ~268 seconds, sufficient for typical delays)

## USB Serial JTAG Output

### How It Works

M5Stack NanoC6 communicates with the host via USB-Serial/JTAG.
Bytes are written to the `USB_DEVICE` peripheral's EP1 FIFO, and transmission is triggered with `wr_done`.

### Implementation

```swift
/// Write a single byte to EP1 FIFO. Skips on timeout if FIFO is full.
private func usbFifoWrite(_ byte: UInt8) -> Bool {
    // Check FIFO availability via serial_in_ep_data_free (ep1_conf bit 1)
    var timeout: UInt32 = 50_000
    while usb_device.ep1_conf.read().raw.storage & (1 << 1) == 0 {
        timeout &-= 1
        if timeout == 0 { return false }
    }
    usb_device.ep1.write { $0.raw.storage = UInt32(byte) }
    return true
}

func usbPrint(_ s: StaticString) {
    var ptr = UnsafeRawPointer(s.utf8Start)
    for _ in 0..<s.utf8CodeUnitCount {
        if !usbFifoWrite(ptr.load(as: UInt8.self)) { return }
        ptr = ptr.advanced(by: 1)
    }
    _ = usbFifoWrite(0x0D) // CR
    _ = usbFifoWrite(0x0A) // LF
    usb_device.ep1_conf.write { $0.raw.storage = 1 }  // Flush (wr_done)
}
```

### Design Points

- **`ep1_conf` bit 1 (`serial_in_ep_data_free`)** checks FIFO availability (same approach as ESP-IDF)
- **With timeout** — does not block when no serial monitor is connected
- **Batch flush** — `wr_done` is called once after all bytes are written. Flushing per byte would generate excessive USB packets that the host cannot process fast enough

### Registers

| Register | Address | Purpose |
|----------|---------|---------|
| `usb_device.ep1` | `0x6000f000` | EP1 FIFO data write (lower 8 bits) |
| `usb_device.ep1_conf` | `0x6000f004` | EP1 control (bit 0 = wr_done, bit 1 = serial_in_ep_data_free) |

### Difference from UART0

The ESP32-C6 bootloader output goes via USB-Serial/JTAG.
The `esp_rom_uart_putc` ROM function outputs to UART0 (GPIO16/17), which does not reach the NanoC6's USB port.
Direct writes to the USB Serial JTAG peripheral are required.
