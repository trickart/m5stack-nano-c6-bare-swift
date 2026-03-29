import Registers
import MMIO

/// Write a byte to EP1 FIFO if space is available.
private func usbFifoWrite(_ byte: UInt8) -> Bool {
    // Check serial_in_ep_data_free (bit 1 of ep1_conf)
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
    _ = usbFifoWrite(0x0D)
    _ = usbFifoWrite(0x0A)
    usb_device.ep1_conf.write { $0.raw.storage = 1 }  // Flush (wr_done)
}
