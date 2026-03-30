# Task 2: ESP32-C6 Bootloader & Flash Image Preparation

## ESP32-C6 Boot Sequence

```
Power ON → ROM Bootloader → 2nd Stage Bootloader → Read Partition Table → Application Start
```

1. **ROM Bootloader** (built into chip, not modifiable)
   - Determines boot mode from GPIO9 strap pin
   - Loads the 2nd stage bootloader from the beginning of SPI Flash (offset `0x0`)
2. **2nd Stage Bootloader** (extracted from ESP-IDF)
   - Reads the partition table at offset `0x8000`
   - Locates the factory app partition (offset `0x10000`)
   - Loads app segments into RAM & configures Flash MMU mapping
   - Jumps to the app entry point
3. **Application** (custom-built)
   - Execution begins from the entry point

## Flash Layout

| Offset | Content | Size | Notes |
|--------|---------|------|-------|
| `0x00000` | bootloader.bin | 21KB | Extracted from ESP-IDF |
| `0x08000` | partition-table.bin | 3KB | Extracted from ESP-IDF |
| `0x10000` | app.bin | Variable | **Custom Swift application** |

### Partition Table Contents

```
nvs      : data, nvs,     0x9000,  0x6000
phy_init : data, phy,     0xf000,  0x1000
factory  : app,  factory, 0x10000, 0x100000 (1MB)
```

## Bootloader Extraction Procedure

Build a minimal project with ESP-IDF and reuse the generated binaries.

### 1. Create a Minimal Project

```bash
mkdir -p /tmp/esp32c6-minimal/main

# main.c
cat > /tmp/esp32c6-minimal/main/main.c << 'EOF'
#include <stdio.h>
void app_main(void) {
    while(1) {}
}
EOF

# main/CMakeLists.txt
cat > /tmp/esp32c6-minimal/main/CMakeLists.txt << 'EOF'
idf_component_register(SRCS "main.c" INCLUDE_DIRS ".")
EOF

# Top-level CMakeLists.txt
cat > /tmp/esp32c6-minimal/CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(minimal)
EOF
```

### 2. Build

```bash
source ~/esp/esp-idf/export.sh
cd /tmp/esp32c6-minimal
idf.py set-target esp32c6
idf.py build
```

### 3. Retrieve Binaries

```bash
cp build/bootloader/bootloader.bin       <project>/bootloader/
cp build/partition_table/partition-table.bin <project>/bootloader/
```

## App Image Generation

### ELF → ESP Image Conversion

Convert the ELF file built with Swift into an ESP32-C6 image using `Tools/elf2image.swift` (pure Swift replacement for esptool.py's `elf2image`).

```bash
TOOLCHAINS=org.swift.630202603201a swift Tools/elf2image.swift \
  --flash_mode dio \
  --flash_freq 80m \
  --flash_size 2MB \
  -o app.bin \
  app.elf
```

### App Image Header Structure

ESP32-C6 app images begin with the following header (24 bytes):

| Offset | Size | Content |
|--------|------|---------|
| 0x00 | 1 | Magic byte (`0xE9`) |
| 0x01 | 1 | Number of segments |
| 0x02 | 1 | Flash mode (DIO=`0x02`) |
| 0x03 | 1 | Flash size/frequency |
| 0x04 | 4 | Entry point address |
| 0x08 | 16 | Extended header (WP pin, SPI drive settings, etc.) |

`elf2image.swift` automatically generates this header (same format as esptool.py), so manual construction is unnecessary.

### Required ELF Segments

`elf2image.swift` reads the loadable segments from the ELF and classifies them based on the following address ranges (same logic as esptool.py):

| Address Range | Classification | Description |
|---------------|---------------|-------------|
| `0x40800000`–`0x40880000` | IRAM/DRAM | Code/data in RAM (copied from Flash at boot) |
| `0x42000000`–`0x42800000` | IROM/DROM | Read-only code/data via Flash MMU |

## Flash Write Command

```bash
TOOLCHAINS=org.swift.630202603201a swift Tools/write-flash.swift \
  0x0     bootloader/bootloader.bin \
  0x8000  bootloader/partition-table.bin \
  0x10000 build/app.bin
```

## Reference

- Bootloader entry point: `0x4086c41a` (IRAM region)
- App entry point: `0x40800250` (IRAM region)
- Bootloader segments: 3 (all loaded into IRAM)
- App segments: 5 (IRAM/DRAM + Flash MMU mapping)
