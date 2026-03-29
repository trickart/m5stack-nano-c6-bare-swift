# Task 6: swift-mmio Integration and Register Definition Generation

## Overview

Using [apple/swift-mmio](https://github.com/apple/swift-mmio), register definitions are auto-generated from the ESP32-C6 SVD file via SVD2Swift.

## Generated Peripherals

| Peripheral | Base Address | Purpose |
|-----------|-------------|---------|
| GPIO | `0x60091000` | GPIO output control (out_w1ts/w1tc, enable, func_out_sel_cfg) |
| IO_MUX | `0x60090000` | Pin function selection (mcu_sel, fun_ie) |
| SYSTIMER | `0x6000a000` | Microsecond delay counter |
| USB_DEVICE | `0x6000f000` | USB Serial JTAG serial output |

## SVD2Swift Generation Procedure

### 1. Obtain the SVD File

```bash
curl -sL "https://raw.githubusercontent.com/esp-rs/esp-pacs/main/esp32c6/svd/esp32c6.base.svd" -o esp32c6.svd
```

### 2. Build SVD2Swift

```bash
git clone https://github.com/apple/swift-mmio.git /tmp/swift-mmio
cd /tmp/swift-mmio
TOOLCHAINS=org.swift.630202603201a swift build -c release --product SVD2Swift
```

### 3. Generate Register Definitions

```bash
/tmp/swift-mmio/.build/release/SVD2Swift \
  --input esp32c6.svd \
  --output Sources/Registers \
  --peripherals GPIO IO_MUX USB_DEVICE SYSTIMER \
  --access-level public
```

### 4. Sendable Conformance

Add `nonisolated(unsafe)` to global variables in the generated `Device.swift`:

```swift
public nonisolated(unsafe) let gpio = GPIO(unsafeAddress: 0x60091000)
```

## Register Access Pattern

Since swift-mmio's BitField projections may have type mismatches in Embedded Swift, access is done via `raw.storage`:

```swift
// GPIO output set (W1TS)
gpio.out_w1ts.write { $0.raw.storage = 1 << UInt32(pin) }

// IO_MUX modify
io_mux.gpio[pin].modify {
    $0.raw.storage = ($0.raw.storage & ~(0x7 << 12)) | (1 << 12)
}
```

## Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/apple/swift-mmio.git", branch: "main"),
],
targets: [
    .target(name: "Registers",
            dependencies: [.product(name: "MMIO", package: "swift-mmio")],
            swiftSettings: [.enableExperimentalFeature("Embedded")]),
    .executableTarget(name: "Application",
                      dependencies: ["Registers"],
                      swiftSettings: [
                          .enableExperimentalFeature("Embedded"),
                          .enableExperimentalFeature("Extern"),
                      ]),
]
```
