# M5Stack NanoC6 Bare-Metal Swift

A bare-metal Swift project for the [M5Stack NanoC6](https://docs.m5stack.com/en/core/M5Stack%20NanoC6) (ESP32-C6), running **without any C, assembly, or ESP-IDF runtime** — pure Embedded Swift from entry point to LED blink.

<p align="center">
  <img src="docs/images/demo.gif" alt="LED blink demo on M5Stack NanoC6" width="320">
</p>

## What This Does

- Boots directly into Swift `@main` — no C startup code
- Disables all 4 watchdog timers via volatile register access
- Drives GPIO7 (blue status LED) through direct IO_MUX / GPIO register manipulation
- Outputs serial messages over USB Serial JTAG
- Implements microsecond delays using the SYSTIMER peripheral
- Provides runtime stubs (`posix_memalign`, `memset`, `memcpy`, `memmove`) entirely in Swift

## Project Structure

```
├── Sources/
│   ├── Application/          # Main application
│   │   ├── Application.swift # @main entry point — LED blink loop
│   │   └── Support/
│   │       ├── Watchdog.swift       # WDT disable (TIMG0/1, LP_WDT, SWD)
│   │       ├── Delay.swift          # SYSTIMER-based microsecond delay
│   │       ├── Serial.swift         # USB Serial JTAG output
│   │       ├── RuntimeStubs.swift   # C stdlib stubs for -nostdlib linking
│   │       └── VolatileRegister.swift
│   └── Registers/            # Auto-generated register definitions (SVD2Swift)
│       ├── Device.swift
│       ├── GPIO.swift
│       ├── IO_MUX.swift
│       ├── SYSTIMER.swift
│       └── USB_DEVICE.swift
├── bootloader/               # Pre-built ESP-IDF bootloader & partition table
├── linker/
│   └── esp32c6.ld            # Custom linker script
├── toolset.json              # Compiler & linker flags
├── Makefile                  # Build & flash automation
├── Package.swift
└── docs/                     # Detailed documentation for each subsystem
```

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Swift 6.3 toolchain | `org.swift.630202603201a` | Must support Embedded Swift & RISC-V |
| ESP-IDF | v5.x | Only needed for `esptool.py` |
| macOS | — | Uses `xcrun` for toolchain discovery |

## Quick Start

### 1. Install Swift 6.3

Install [swiftly](https://swiftlang.github.io/swiftly/) (Swift toolchain manager), then install the Swift 6.3 snapshot:

```bash
# Install swiftly
curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash

# Install Swift 6.3
swiftly install 6.3

# Set the toolchain for this project
export TOOLCHAINS=org.swift.630202603201a
```

### 2. Install ESP-IDF

ESP-IDF is needed for `esptool.py` (flash image generation and writing). Only the tooling is used — the ESP-IDF runtime is not linked.

```bash
mkdir -p ~/esp && cd ~/esp
git clone --depth 1 --branch v5.4 https://github.com/espressif/esp-idf.git
cd esp-idf
git submodule update --init --depth 1
./install.sh

# Activate ESP-IDF tools (needed in every new shell session)
source ~/esp/esp-idf/export.sh
```

### 3. Build

```bash
make build
```

This runs `swift build` for the `riscv32-none-none-eabi` target, then converts the ELF to an ESP flash image.

### 4. Flash

```bash
make flash
```

Writes the bootloader, partition table, and application to the NanoC6.

### 5. Monitor

```bash
screen /dev/cu.usbmodem* 115200
```

You should see `Swift: blinking` messages and the blue LED toggling every 500ms.

## How It Works

The ESP-IDF 2nd stage bootloader handles low-level initialization (stack pointer, segment loading, Flash MMU), then jumps to the Swift `@main` entry point. From there, everything is pure Swift:

1. **Disable watchdogs** — The bootloader leaves WDTs enabled; without feeding them, the chip resets after a few seconds
2. **Configure GPIO7** — Set IO_MUX to GPIO function, route through GPIO matrix, enable output
3. **Blink loop** — Toggle output via W1TS/W1TC registers with SYSTIMER-based delays

Register access uses [apple/swift-mmio](https://github.com/apple/swift-mmio) with definitions generated from the ESP32-C6 SVD file.

## Documentation

Detailed write-ups for each subsystem are in the [`docs/`](docs/) directory:

| Doc | Topic |
|-----|-------|
| [01-toolchain](docs/01-toolchain.md) | Toolchain setup |
| [02-bootloader-flash-image](docs/02-bootloader-flash-image.md) | Boot sequence & flash image format |
| [03-linker-script](docs/03-linker-script.md) | Memory map & linker script design |
| [04-startup](docs/04-startup.md) | Pure Swift startup & watchdog disabling |
| [05-runtime-stubs](docs/05-runtime-stubs.md) | C stdlib stubs in Swift |
| [06-swift-mmio](docs/06-swift-mmio.md) | swift-mmio integration & SVD2Swift |
| [07-gpio](docs/07-gpio.md) | GPIO driver implementation |
| [08-delay-serial](docs/08-delay-serial.md) | SYSTIMER delay & USB Serial JTAG output |
| [09-build-system](docs/09-build-system.md) | Build pipeline (SwiftPM + toolset + Make) |

## Acknowledgments

- [pico-bare-swift](https://github.com/kishikawakatsumi/pico-bare-swift) — Inspiration for the `@main` bare-metal pattern and `VolatileMappedRegister` usage
- [esp32-c6-swift-baremetal](https://github.com/georgik/esp32-c6-swift-baremetal) — Reference for ESP32-C6 + Swift bare-metal approach
- [apple/swift-mmio](https://github.com/apple/swift-mmio) — MMIO register access framework and SVD2Swift code generator

## License

This project is licensed under the [Apache License 2.0](LICENSE).
