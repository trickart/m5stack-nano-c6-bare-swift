# Task 10: Tools

## Overview

The `Tools/` directory contains Swift scripts that handle build and flash operations with no external dependencies.
All scripts can be run directly with `TOOLCHAINS=org.swift.630202603201a swift Tools/<script>.swift`.

| Tool | Role |
|------|------|
| `elf2image.swift` | ELF to ESP32-C6 flash image conversion |
| `write-flash.swift` | Flash writing to device via serial |
| `image-info.swift` | Display header information of a generated image |
| `gen-partition-table.swift` | Generate ESP32-C6 partition table binary |

## elf2image.swift

Converts an ELF binary into a flash image (.bin) recognized by the ESP32-C6 ROM bootloader.
Equivalent to esptool.py's `elf2image` subcommand.

### Usage

```
swift elf2image.swift --flash_mode dio --flash_freq 80m --flash_size 2MB -o out.bin input.elf
```

### Processing Pipeline

```
ELF binary
  ↓ Parse ELF header / Program headers
  ↓ Extract LOAD segments (RAM / Flash-mapped)
  ↓ Generate ESP image header (magic 0xE9)
  ↓ Write segment headers + data
  ↓ Compute and append checksum
  ↓ Append SHA-256 hash
ESP flash image (.bin)
```

### ESP Image Header Structure

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0x00 | 1 | magic | `0xE9` (ESP image magic) |
| 0x01 | 1 | segment_count | Number of LOAD segments |
| 0x02 | 1 | flash_mode | SPI mode (0=QIO, 2=DIO) |
| 0x03 | 1 | flash_config | Size (upper 4 bits) + Frequency (lower 4 bits) |
| 0x04 | 4 | entry_addr | Entry point address |
| 0x08 | 16 | extended_header | Chip ID, flags, etc. |

### Flash Mode / Size / Freq Mapping

| Parameter | Value | Encoding |
|-----------|-------|----------|
| `--flash_mode dio` | Dual I/O | `0x02` |
| `--flash_size 2MB` | 2 MB | `0x10` (upper 4 bits) |
| `--flash_freq 80m` | 80 MHz | `0x0F` (lower 4 bits) |

## write-flash.swift

Communicates with the ESP32-C6 ROM bootloader via the SLIP protocol to write flash memory.
Equivalent to esptool.py's `write_flash` subcommand.

### Usage

```
swift write-flash.swift [-b baud] [-p port] [--trace] <addr1> <file1> [<addr2> <file2> ...]
```

| Option | Default | Description |
|--------|---------|-------------|
| `-b` | `460800` | Baud rate for writing |
| `-p` | auto-detect | Serial port (auto-detects `/dev/cu.usbmodem*`) |
| `--trace` | off | Print SLIP packet trace to stderr |

### Communication Flow

```
1. Open serial port (115200 baud)
2. Reset into bootloader mode via DTR/RTS control
3. SYNC command to synchronize
4. CHANGE_BAUD to switch baud rate (460800)
5. SPI_ATTACH to enable SPI flash
6. SPI_SET_PARAMS to configure flash parameters
7. For each region:
   a. FLASH_BEGIN (erase)
   b. FLASH_DATA × N (1KB block writes)
   c. SPI_FLASH_MD5 (verify)
8. Hard reset via RTS
```

### ROM Loader Commands

| Command | Code | Description |
|---------|------|-------------|
| `ESP_SYNC` | `0x08` | Synchronize with bootloader |
| `ESP_READ_REG` | `0x0A` | Read register |
| `ESP_SPI_SET_PARAMS` | `0x0B` | Set SPI flash parameters |
| `ESP_SPI_ATTACH` | `0x0D` | Enable SPI flash |
| `ESP_CHANGE_BAUD` | `0x0F` | Change baud rate |
| `ESP_FLASH_BEGIN` | `0x02` | Begin flash write (performs erase) |
| `ESP_FLASH_DATA` | `0x03` | Send flash data block |
| `ESP_FLASH_END` | `0x04` | End flash write |
| `ESP_SPI_FLASH_MD5` | `0x13` | Compute MD5 of flash region |

### SLIP Protocol

Communication with the ROM bootloader is framed using SLIP (RFC 1055).

| Byte | Meaning |
|------|---------|
| `0xC0` | Frame delimiter (start/end) |
| `0xDB 0xDC` | Escape for `0xC0` within data |
| `0xDB 0xDD` | Escape for `0xDB` within data |

### Response Packet Structure

```
C0 [direction=0x01] [cmd] [size_lo] [size_hi] [val (4B LE)] [body (size bytes)] C0
```

| Field | Size | Description |
|-------|------|-------------|
| direction | 1 | `0x01` = response |
| cmd | 1 | Command code (matches request) |
| size | 2 | Body length in bytes (LE) |
| value | 4 | Command-specific return value (LE) |
| body | size | Response data + status |

### Response Body Status Interpretation

The ESP32-C6 ROM bootloader response body has the following layout:

```
[resp_data (resp_data_len bytes)] [status (1B)] [error (1B)] [reserved (2B)]
```

For normal commands (`resp_data_len=0`), the body is 4 bytes:
- `body[0]` = status (0 = success)
- `body[1]` = error code
- `body[2..3]` = reserved (must be ignored)

For the MD5 command (`resp_data_len=32`), the body is 36 bytes:
- `body[0..31]` = MD5 hash (ASCII hex, 32 characters)
- `body[32]` = status
- `body[33]` = error code
- `body[34..35]` = reserved

**Important**: The status byte position is determined by `resp_data_len`. Reading the last 2 bytes
(`body[size-2..size-1]`) as status is **incorrect** — the reserved bytes may contain residual data
from the ROM's internal buffer. esptool.py's `check_command` determines the status position the same way.

## image-info.swift

Displays header information of a generated ESP flash image.
Equivalent to esptool.py's `image_info` subcommand.

### Usage

```
swift image-info.swift <image.bin>
```

Displays the magic byte, segment count, entry point, flash configuration, and address/size of each segment.

## gen-partition-table.swift

Generates a binary partition table (3072 bytes) matching the ESP32 partition table format.
See [02-bootloader-flash-image.md](02-bootloader-flash-image.md) for the partition layout.

### Usage

```
swift gen-partition-table.swift [-o output.bin]
```

## Makefile Integration

```makefile
SWIFT_RUN := TOOLCHAINS=$(TOOLCHAINS) swift

build:
    swift build --triple $(TRIPLE) --toolset toolset.json
    $(SWIFT_RUN) Tools/elf2image.swift ... -o $(BIN) $(ELF)

partition-table:
    $(SWIFT_RUN) Tools/gen-partition-table.swift -o $(PARTITION_BIN)

bootloader:
    swift build --triple $(TRIPLE) --toolset toolset-bootloader.json --product Bootloader
    $(SWIFT_RUN) Tools/elf2image.swift ... -o $(BOOTLOADER_BIN) $(BOOTLOADER_ELF)

flash: build bootloader partition-table
    $(SWIFT_RUN) Tools/write-flash.swift -b 460800 \
        0x0 $(BOOTLOADER_BIN) \
        0x8000 $(PARTITION_BIN) \
        0x10000 $(BIN)

image_info: build
    $(SWIFT_RUN) Tools/image-info.swift $(BIN)
```

The full build-to-flash pipeline requires only the Swift toolchain (`org.swift.630202603201a`) — no ESP-IDF or other external tools needed.
