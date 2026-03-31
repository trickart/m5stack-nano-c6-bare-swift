import Registers
import MMIO

func usbPrintHex(_ value: UInt) {
    let hexDigits = StaticString("0123456789ABCDEF")
    let digits = hexDigits.utf8Start
    var shift = 28
    while shift >= 0 {
        let nibble = (value >> UInt(shift)) & 0xF
        _ = usbFifoWrite(digits.advanced(by: Int(nibble)).pointee)
        shift &-= 4
    }
}

func usbPrintLabeled(_ label: StaticString, _ value: UInt) {
    var ptr = UnsafeRawPointer(label.utf8Start)
    for _ in 0..<label.utf8CodeUnitCount {
        _ = usbFifoWrite(ptr.load(as: UInt8.self))
        ptr = ptr.advanced(by: 1)
    }
    usbPrintHex(value)
    _ = usbFifoWrite(0x0D)
    _ = usbFifoWrite(0x0A)
    usb_device.ep1_conf.write { $0.raw.storage = 1 }
}

@_extern(c, "posix_memalign")
func posix_memalign(
    _ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: Int,
    _ size: Int
) -> Int32

@_extern(c, "free")
func free(_ ptr: UnsafeMutableRawPointer?)

func testHeapAllocator() {
    usbPrint("=== Heap allocator test ===")

    var p1: UnsafeMutableRawPointer? = nil
    var p2: UnsafeMutableRawPointer? = nil
    var p3: UnsafeMutableRawPointer? = nil

    // Test 1: Basic allocation
    let r1 = posix_memalign(&p1, 4, 64)
    usbPrintLabeled("alloc1 ret=", UInt(r1))
    usbPrintLabeled("alloc1 ptr=", UInt(bitPattern: p1))

    // Test 2: Second allocation
    let r2 = posix_memalign(&p2, 4, 128)
    usbPrintLabeled("alloc2 ret=", UInt(r2))
    usbPrintLabeled("alloc2 ptr=", UInt(bitPattern: p2))

    // Test 3: Aligned allocation (16-byte)
    let r3 = posix_memalign(&p3, 16, 32)
    usbPrintLabeled("alloc3 ret=", UInt(r3))
    usbPrintLabeled("alloc3 ptr=", UInt(bitPattern: p3))
    usbPrintLabeled("alloc3 align check (expect 0)=", UInt(bitPattern: p3) & 0xF)

    // Test 4: Write to allocated memory
    if let p = p1 {
        p.storeBytes(of: UInt32(0xDEADBEEF), as: UInt32.self)
        let readBack = p.load(as: UInt32.self)
        usbPrintLabeled("write/read (expect DEADBEEF)=", UInt(readBack))
    }

    // Test 5: Free and re-allocate
    let addr1 = UInt(bitPattern: p1)
    free(p1)
    free(p2)

    var p4: UnsafeMutableRawPointer? = nil
    let r4 = posix_memalign(&p4, 4, 64)
    usbPrintLabeled("realloc ret=", UInt(r4))
    usbPrintLabeled("realloc ptr=", UInt(bitPattern: p4))
    if UInt(bitPattern: p4) == addr1 {
        usbPrint("PASS: memory reused after free")
    } else {
        usbPrint("INFO: realloc at different addr (coalesced)")
    }

    // Test 6: Free all, allocate large block (coalescing)
    free(p3)
    free(p4)
    var pBig: UnsafeMutableRawPointer? = nil
    let rBig = posix_memalign(&pBig, 4, 256)
    if rBig == 0 {
        usbPrint("PASS: large alloc after free succeeded")
    }
    free(pBig)

    // Test 7: 100 alloc/free cycles
    var ok = true
    for _ in 0..<100 {
        var tmp: UnsafeMutableRawPointer? = nil
        if posix_memalign(&tmp, 4, 128) != 0 {
            ok = false
            break
        }
        free(tmp)
    }
    if ok {
        usbPrint("PASS: 100 alloc/free cycles OK")
    } else {
        usbPrint("FAIL: alloc/free cycle exhausted heap")
    }

    usbPrint("=== Test complete ===")
}

@main
struct Application {
    static func main() {
        clearBSS()
        disableWatchdogs()

        delayUs(2_000_000)
        testHeapAllocator()

        usbPrint("Swift: GPIO init")

        let ledPin: Int = 7

        // 1. IO_MUX: mcu_sel=1 (GPIO function), fun_ie=0
        io_mux.gpio[ledPin].modify {
            $0.raw.storage = ($0.raw.storage & ~(0x7 << 12)) | (1 << 12)
            $0.raw.storage = $0.raw.storage & ~(1 << 9)
        }

        // 2. GPIO matrix: func_out_sel=128, func_oen_sel=1
        gpio.func_out_sel_cfg[ledPin].modify {
            $0.raw.storage = 128 | (1 << 9)
        }

        // 3. Enable output
        gpio.enable_w1ts.write { $0.raw.storage = 1 << UInt32(ledPin) }

        usbPrint("Swift: blinking")

        // 4. Blink loop
        while true {
            gpio.out_w1ts.write { $0.raw.storage = 1 << UInt32(ledPin) }
            delayUs(500_000)
            gpio.out_w1tc.write { $0.raw.storage = 1 << UInt32(ledPin) }
            delayUs(500_000)

            usbPrint("Swift: blinking")
        }
    }
}
