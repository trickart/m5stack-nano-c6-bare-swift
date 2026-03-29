# Task 7: GPIO Driver Implementation (Without ROM Functions)

## Overview

GPIO7 output control using swift-mmio register definitions. Direct IO_MUX / GPIO register manipulation without ROM functions.

## Registers Used

| Register | Address | Purpose |
|----------|---------|---------|
| `io_mux.gpio[7]` | `0x60090020` | Pin function selection (mcu_sel), input disable (fun_ie) |
| `gpio.func_out_sel_cfg[7]` | `0x60091570` | Output signal routing (func_out_sel=128 for direct GPIO_OUT_REG) |
| `gpio.enable_w1ts` | `0x60091024` | Output enable (Write 1 To Set) |
| `gpio.out_w1ts` | `0x60091008` | Output High (Write 1 To Set) |
| `gpio.out_w1tc` | `0x6009100C` | Output Low (Write 1 To Clear) |

## Initialization Procedure

```swift
let ledPin: Int = 7

// 1. IO_MUX: mcu_sel=1 (GPIO function), fun_ie=0 (input disable)
io_mux.gpio[ledPin].modify {
    $0.raw.storage = ($0.raw.storage & ~(0x7 << 12)) | (1 << 12)
    $0.raw.storage = $0.raw.storage & ~(1 << 9)
}

// 2. GPIO matrix: func_out_sel=128 (GPIO_OUT_REG direct), func_oen_sel=1
gpio.func_out_sel_cfg[ledPin].modify {
    $0.raw.storage = 128 | (1 << 9)
}

// 3. Enable output
gpio.enable_w1ts.write { $0.raw.storage = 1 << UInt32(ledPin) }
```

### Explanation of Each Step

1. **IO_MUX**: `mcu_sel=1` sets the pin to GPIO function (Function 1). `fun_ie=0` disables input
2. **GPIO matrix**: `func_out_sel=128` means "output GPIO_OUT_REG value directly". `func_oen_sel=1` means "control output enable via GPIO_ENABLE_REG"
3. **Enable**: Writing a bit to the W1TS register enables output for the corresponding GPIO

## High/Low Control

```swift
gpio.out_w1ts.write { $0.raw.storage = 1 << UInt32(ledPin) }  // High
gpio.out_w1tc.write { $0.raw.storage = 1 << UInt32(ledPin) }  // Low
```

W1TS (Write 1 To Set) / W1TC (Write 1 To Clear) operate atomically without requiring read-modify-write.

## M5Stack NanoC6 LED Pins

| GPIO | Function |
|------|----------|
| **GPIO7** | Blue status LED (simple High/Low control) |
| GPIO20 | WS2812 RGB LED (requires RMT protocol) |
| GPIO19 | RGB LED power enable |
| GPIO9 | Button |
