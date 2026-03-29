import Registers
import MMIO

@main
struct Application {
    static func main() {
        disableWatchdogs()
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
