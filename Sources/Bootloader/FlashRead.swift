// SPI Flash reading via direct SPI1 register access.
//
// Configures SPI1 for DIO flash read mode, matching the ROM bootloader's
// register settings, then reads flash data using the USR command mechanism.

import _Volatile

// MARK: - SPI1 Register Addresses (base = 0x6000_3000)

private let SPI1_CMD_REG: UInt32    = 0x6000_3000       // + 0x00
private let SPI1_ADDR_REG: UInt32   = 0x6000_3004       // + 0x04
private let SPI1_USER_REG: UInt32   = 0x6000_3018       // + 0x18
private let SPI1_USER1_REG: UInt32  = 0x6000_301C       // + 0x1C
private let SPI1_USER2_REG: UInt32  = 0x6000_3020       // + 0x20
private let SPI1_MISO_DLEN: UInt32  = 0x6000_3028       // + 0x28
private let SPI1_W0_REG: UInt32     = 0x6000_3058       // + 0x58

// CMD_REG
private let SPI_MEM_USR: UInt32 = 1 << 18

// USER_REG mode bits (bits 31-27)
private let SPI_MEM_USR_COMMAND: UInt32 = 1 << 31
private let SPI_MEM_USR_ADDR: UInt32    = 1 << 30
private let SPI_MEM_USR_DUMMY: UInt32   = 1 << 29
private let SPI_MEM_USR_MISO: UInt32    = 1 << 28
private let SPI_MEM_USR_MOSI: UInt32    = 1 << 27
private let SPI_USER_MODE_MASK: UInt32  = 0xF8000000  // bits 31-27

// USER1_REG fields
private let SPI_MEM_USR_ADDR_BITLEN_S: UInt32    = 26
private let SPI_MEM_USR_ADDR_BITLEN_M: UInt32     = 0x3F << 26
private let SPI_MEM_USR_DUMMY_CYCLELEN_M: UInt32  = 0x3F

// USER2_REG fields
private let SPI_MEM_USR_COMMAND_BITLEN_S: UInt32  = 28

// DIO mode settings (determined by reading ROM function's register state)
private let DIO_ADDR_BITLEN: UInt32    = 27   // 28-bit address phase (24-bit addr + 4-bit mode)
private let DIO_DUMMY_CYCLELEN: UInt32 = 1    // 2 dummy clock cycles
private let DIO_COMMAND: UInt32        = 0xBB // Fast Read Dual I/O
private let DIO_COMMAND_BITLEN: UInt32 = 7    // 8-bit command

private let SPI_READ_MAX: UInt32 = 16

// MARK: - SPI Read Mode Configuration

/// Configure SPI1 for DIO flash reads, matching the ROM bootloader's settings.
/// Must be called before any readFlash() call.
func configureSpiReadMode() {
    // USER_REG: set COMMAND + ADDR + DUMMY + MISO, clear MOSI, preserve lower bits
    let user = regLoad(SPI1_USER_REG)
    regStore(SPI1_USER_REG,
             (user & ~SPI_USER_MODE_MASK) |
             SPI_MEM_USR_COMMAND | SPI_MEM_USR_ADDR | SPI_MEM_USR_DUMMY | SPI_MEM_USR_MISO)

    // USER1_REG: addr_bitlen=27, dummy_cyclelen=1
    let user1 = regLoad(SPI1_USER1_REG)
    regStore(SPI1_USER1_REG,
             (user1 & ~(SPI_MEM_USR_ADDR_BITLEN_M | SPI_MEM_USR_DUMMY_CYCLELEN_M)) |
             (DIO_ADDR_BITLEN << SPI_MEM_USR_ADDR_BITLEN_S) |
             DIO_DUMMY_CYCLELEN)

    // USER2_REG: command_bitlen=7, command_value=0xBB
    regStore(SPI1_USER2_REG, (DIO_COMMAND_BITLEN << SPI_MEM_USR_COMMAND_BITLEN_S) | DIO_COMMAND)
}

// MARK: - Flash Read

/// Read data from SPI flash into a RAM buffer.
func readFlash(src: UInt32, dest: UnsafeMutableRawPointer, length: Int) {
    var addr = src
    var remaining = UInt32(length)
    var byteOffset = 0

    while remaining > 0 {
        let chunk = min(remaining, SPI_READ_MAX)

        // Set flash address
        regStore(SPI1_ADDR_REG, addr)

        // Set read data bit length
        regStore(SPI1_MISO_DLEN, chunk * 8 - 1)

        // Trigger user-mode SPI command
        regStore(SPI1_CMD_REG, regLoad(SPI1_CMD_REG) | SPI_MEM_USR)

        // Wait for completion
        while regLoad(SPI1_CMD_REG) != 0 {}

        // Copy data from W0+ buffer registers
        let words = Int((chunk + 3) >> 2)
        for i in 0..<words {
            let w = regLoad(SPI1_W0_REG + UInt32(i) * 4)
            let bytesLeft = Int(chunk) - i * 4
            if bytesLeft >= 4 {
                let p = (dest + byteOffset + i * 4).assumingMemoryBound(to: UInt32.self)
                p.pointee = w
            } else {
                let p = (dest + byteOffset + i * 4).assumingMemoryBound(to: UInt8.self)
                for b in 0..<bytesLeft {
                    (p + b).pointee = UInt8(truncatingIfNeeded: w >> (b * 8))
                }
            }
        }

        addr += chunk
        remaining -= chunk
        byteOffset += Int(chunk)
    }
}

/// Read a UInt32 from flash at the given offset.
func readFlashUInt32(at offset: UInt32) -> UInt32 {
    var value: UInt32 = 0
    withUnsafeMutableBytes(of: &value) { buf in
        readFlash(src: offset, dest: buf.baseAddress!, length: 4)
    }
    return value
}

/// Read a UInt8 from flash at the given offset.
func readFlashUInt8(at offset: UInt32) -> UInt8 {
    let aligned = offset & ~3
    var word: UInt32 = 0
    withUnsafeMutableBytes(of: &word) { buf in
        readFlash(src: aligned, dest: buf.baseAddress!, length: 4)
    }
    let byteOffset = offset & 3
    return UInt8(truncatingIfNeeded: word >> (byteOffset * 8))
}
