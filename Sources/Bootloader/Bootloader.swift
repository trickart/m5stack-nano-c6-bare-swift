// Minimal 2nd-stage bootloader for ESP32-C6, written in pure Swift.
//
// Boot flow:
//   ROM Bootloader → this code → read partition table → find factory app
//   → load RAM segments → setup Flash MMU → jump to app entry point

// MARK: - Constants

let ESP_IMAGE_MAGIC: UInt8    = 0xE9
let PARTITION_TABLE_OFFSET: UInt32 = 0x8000
let PARTITION_ENTRY_SIZE: Int = 32
let PARTITION_MAGIC: UInt16   = 0x50AA
let PARTITION_MD5_MAGIC: UInt16 = 0xEBEB

// Partition types/subtypes
let PART_TYPE_APP: UInt8      = 0x00
let PART_SUBTYPE_FACTORY: UInt8 = 0x00

// Memory regions
let IRAM_START: UInt32 = 0x4080_0000
let IRAM_END: UInt32   = 0x4088_0000

// MARK: - Image Header

struct ESPImageHeader {
    let magic: UInt8
    let segmentCount: UInt8
    let flashMode: UInt8
    let flashConfig: UInt8
    let entryPoint: UInt32
}

func readImageHeader(at flashOffset: UInt32) -> ESPImageHeader {
    var buf = (UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0))
    withUnsafeMutableBytes(of: &buf) { ptr in
        readFlash(src: flashOffset, dest: ptr.baseAddress!, length: 24)
    }
    let bytes = withUnsafeBytes(of: buf) { Array($0) }
    return ESPImageHeader(
        magic: bytes[0],
        segmentCount: bytes[1],
        flashMode: bytes[2],
        flashConfig: bytes[3],
        entryPoint: UInt32(bytes[4])
            | (UInt32(bytes[5]) << 8)
            | (UInt32(bytes[6]) << 16)
            | (UInt32(bytes[7]) << 24)
    )
}

// MARK: - Partition Table

struct PartitionInfo {
    let offset: UInt32
    let size: UInt32
}

/// Search partition table for the factory app partition.
/// Only reads the first few entries (enough for a simple partition table).
func findFactoryApp() -> PartitionInfo? {
    let maxEntries = 8  // Enough for typical partition tables
    // Use a stack-allocated buffer (256 bytes) to avoid heap dependency
    var rawBuf: (
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32,
        UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32
    ) = (
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
    )
    let bufSize = maxEntries * PARTITION_ENTRY_SIZE  // 256 bytes
    withUnsafeMutableBytes(of: &rawBuf) { ptr in
        readFlash(src: PARTITION_TABLE_OFFSET, dest: ptr.baseAddress!, length: bufSize)
    }

    let bytes = withUnsafeBytes(of: &rawBuf) { $0.bindMemory(to: UInt8.self).baseAddress! }

    for i in 0..<maxEntries {
        let base = i * PARTITION_ENTRY_SIZE
        let magic = UInt16(bytes[base]) | (UInt16(bytes[base + 1]) << 8)

        // End of table
        if magic == 0xFFFF { break }
        // MD5 entry
        if magic == PARTITION_MD5_MAGIC { break }
        // Invalid entry
        if magic != PARTITION_MAGIC { continue }

        let type = bytes[base + 2]
        let subtype = bytes[base + 3]

        if type == PART_TYPE_APP && subtype == PART_SUBTYPE_FACTORY {
            let offset = UInt32(bytes[base + 4])
                | (UInt32(bytes[base + 5]) << 8)
                | (UInt32(bytes[base + 6]) << 16)
                | (UInt32(bytes[base + 7]) << 24)
            let size = UInt32(bytes[base + 8])
                | (UInt32(bytes[base + 9]) << 8)
                | (UInt32(bytes[base + 10]) << 16)
                | (UInt32(bytes[base + 11]) << 24)
            return PartitionInfo(offset: offset, size: size)
        }
    }
    return nil
}

// MARK: - Segment Loading

/// Load RAM segments (IRAM/DRAM) from the app image into their target addresses.
func loadRAMSegments(appFlashOffset: UInt32, segmentCount: UInt8) {
    var fileOffset = appFlashOffset + 24  // skip 24-byte image header

    for _ in 0..<segmentCount {
        let loadAddr = readFlashUInt32(at: fileOffset)
        let dataLen  = readFlashUInt32(at: fileOffset + 4)
        let dataStart = fileOffset + 8

        // Only load segments targeted at IRAM/DRAM (0x40800000-0x40880000)
        if loadAddr >= IRAM_START && loadAddr < IRAM_END && dataLen > 0 {
            let dest = UnsafeMutableRawPointer(bitPattern: UInt(loadAddr))!
            readFlash(src: dataStart, dest: dest, length: Int(dataLen))
        }

        fileOffset = dataStart + dataLen
    }
}

// MARK: - BSS Initialization

@_extern(c, "_sbss") nonisolated(unsafe) var _sbss: UInt8
@_extern(c, "_ebss") nonisolated(unsafe) var _ebss: UInt8

func clearBSS() {
    let start = linkerSymbolAddress(&_sbss)
    let end = linkerSymbolAddress(&_ebss)
    guard let ptr = UnsafeMutablePointer<UInt8>(bitPattern: start) else { return }
    var i = 0
    while start &+ UInt(i) < end {
        ptr[i] = 0
        i &+= 1
    }
}

@main
struct Bootloader {
    static func main() {
        clearBSS()
        disableWatchdogs()
        configureFlashSPI()

        // Find factory app partition
        guard let app = findFactoryApp() else {
            while true {}  // Hang: no factory partition found
        }

        // Read app image header
        let header = readImageHeader(at: app.offset)
        guard header.magic == ESP_IMAGE_MAGIC else {
            while true {}  // Hang: invalid image
        }

        // Load RAM segments (IRAM/DRAM) from flash to their target addresses
        loadRAMSegments(appFlashOffset: app.offset, segmentCount: header.segmentCount)

        // Set up Flash MMU for IROM/DROM segments
        setupFlashMMU(appFlashOffset: app.offset, segmentCount: header.segmentCount)

        // Wait for USB host to re-enumerate after reset
        delayMs(500)

        // Jump to application entry point
        let entry = unsafeBitCast(
            UInt(header.entryPoint),
            to: (@convention(c) () -> Void).self
        )
        entry()

        // Should never reach here
        while true {}
    }
}
