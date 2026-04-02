import Registers
import MMIO

// MARK: - Low-level USB Serial JTAG I/O

/// Write a byte to EP1 FIFO if space is available.
func usbFifoWrite(_ byte: UInt8) -> Bool {
    var timeout: UInt32 = 50_000
    while usb_device.ep1_conf.read().raw.storage & (1 << 1) == 0 {
        timeout &-= 1
        if timeout == 0 { return false }
    }
    usb_device.ep1.write { $0.raw.storage = UInt32(byte) }
    return true
}

/// Flush EP1 FIFO (trigger wr_done).
func usbFlush() {
    usb_device.ep1_conf.write { $0.raw.storage = 1 }
}

/// Write raw bytes to USB Serial JTAG without CR+LF.
func usbWriteBytes(_ ptr: UnsafePointer<UInt8>, count: Int) {
    for i in 0..<count {
        if !usbFifoWrite(ptr[i]) { return }
    }
    usbFlush()
}

// MARK: - String Output

/// Print a StaticString inline (no newline).
func usbPrintStr(_ s: StaticString) {
    var ptr = UnsafeRawPointer(s.utf8Start)
    for _ in 0..<s.utf8CodeUnitCount {
        if !usbFifoWrite(ptr.load(as: UInt8.self)) { return }
        ptr = ptr.advanced(by: 1)
    }
}

/// Print a StaticString followed by CR+LF.
func usbPrint(_ s: StaticString) {
    usbPrintStr(s)
    _ = usbFifoWrite(0x0D)
    _ = usbFifoWrite(0x0A)
    usbFlush()
}

// MARK: - Numeric Output

/// Print a decimal integer inline (no newline).
func usbPrintInt(_ value: Int) {
    if value == 0 {
        _ = usbFifoWrite(0x30)
        usbFlush()
        return
    }
    var n = value
    var negative = false
    if n < 0 {
        negative = true
        n = 0 &- n
    }
    var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var i = 0
    while n > 0 {
        withUnsafeMutablePointer(to: &buf) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 11) { p in
                p[i] = UInt8(truncatingIfNeeded: n % 10) &+ 0x30
            }
        }
        n /= 10
        i &+= 1
    }
    if negative { _ = usbFifoWrite(0x2D) }
    while i > 0 {
        i &-= 1
        let ch: UInt8 = withUnsafePointer(to: buf) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 11) { p in p[i] }
        }
        _ = usbFifoWrite(ch)
    }
    usbFlush()
}

/// Print a Double value inline (integer part + 6 decimal places, no newline).
func usbPrintDouble(_ value: Double) {
    var v = value
    if v < 0.0 {
        _ = usbFifoWrite(0x2D)
        v = 0.0 - v
    }

    let intPart = Int(v)
    usbPrintInt(intPart)
    _ = usbFifoWrite(0x2E)

    var frac = v - Double(intPart)
    var digits: Int32 = 0
    while digits < 6 {
        frac = frac * 10.0
        let digit = Int(frac)
        _ = usbFifoWrite(UInt8(digit) &+ 0x30)
        frac = frac - Double(digit)
        digits &+= 1
    }
    usbFlush()
}

/// Print a Float value inline (integer part + 4 decimal places, no newline).
func usbPrintFloat(_ value: Float) {
    var v = value
    if v < 0.0 {
        _ = usbFifoWrite(0x2D)
        v = 0.0 - v
    }

    let intPart = Int(v)
    usbPrintInt(intPart)
    _ = usbFifoWrite(0x2E)

    var frac = v - Float(intPart)
    var digits: Int32 = 0
    while digits < 4 {
        frac = frac * 10.0
        let digit = Int(frac)
        _ = usbFifoWrite(UInt8(digit) &+ 0x30)
        frac = frac - Float(digit)
        digits &+= 1
    }
    usbFlush()
}
