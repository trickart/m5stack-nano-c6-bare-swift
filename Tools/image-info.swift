// image-info.swift — ESP32 image header info display
// Usage: swift image-info.swift <image.bin>

import Foundation
import CommonCrypto

// MARK: - Constants

let IROM_MAP_START: UInt32 = 0x42000000
let IROM_MAP_END:   UInt32 = 0x42800000
let DROM_MAP_START: UInt32 = 0x42800000
let DROM_MAP_END:   UInt32 = 0x43000000
let IRAM_START:     UInt32 = 0x40800000
let IRAM_END:       UInt32 = 0x40880000
let DRAM_START:     UInt32 = 0x40800000
let DRAM_END:       UInt32 = 0x40880000

let flashModeNames: [UInt8: String] = [0: "QIO", 1: "QOUT", 2: "DIO", 3: "DOUT"]
let flashSizeNames: [UInt8: String] = [
    0x00: "1MB", 0x10: "2MB", 0x20: "4MB", 0x30: "8MB",
    0x40: "16MB", 0x50: "32MB", 0x60: "64MB", 0x70: "128MB",
]
let flashFreqNames: [UInt8: String] = [0x00: "80m", 0x02: "20m"]

// MARK: - Memory type classification

func memoryType(_ addr: UInt32) -> String {
    if addr == 0 { return "PADDING" }
    var types: [String] = []
    if DROM_MAP_START <= addr && addr < DROM_MAP_END { types.append("DROM") }
    if IROM_MAP_START <= addr && addr < IROM_MAP_END { types.append("DROM"); types.append("IROM") }
    if DRAM_START <= addr && addr < DRAM_END { types.append("DRAM"); types.append("BYTE_ACCESSIBLE") }
    if IRAM_START <= addr && addr < IRAM_END { types.append("IRAM") }
    return types.isEmpty ? "UNKNOWN" : types.joined(separator: ",")
}

// MARK: - Helpers

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        self.subdata(in: offset..<(offset+2)).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }
    func u32(_ offset: Int) -> UInt32 {
        self.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }
}

func hexStr(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift image-info.swift <image.bin>\n", stderr)
    exit(1)
}

let path = CommandLine.arguments[1]
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    fputs("Error: Cannot read '\(path)'\n", stderr)
    exit(1)
}

guard data.count >= 24, data[0] == 0xE9 else {
    fputs("Error: Not a valid ESP image (bad magic)\n", stderr)
    exit(1)
}

// Common header (8 bytes)
let segmentCount = Int(data[1])
let flashMode = data[2]
let flashSizeFreq = data[3]
let entrypoint = data.u32(4)

// Extended header (16 bytes at offset 8)
let wpPin = data[8]
let chipId = data.u16(12)
let minRev = data[14]
let minRevFull = data.u16(15)
let maxRevFull = data.u16(17)
let appendDigest = data[23]

print("File size: \(data.count) (bytes)")
print("Image version: 1")
print("Entry point: \(String(format: "%08x", entrypoint))")
print("\(segmentCount) segments")
print("")

// Read segments
var offset = 24  // after common + extended header
var checksumState: UInt8 = 0xEF

for i in 0..<segmentCount {
    guard offset + 8 <= data.count else {
        fputs("Error: Truncated image at segment \(i+1)\n", stderr)
        exit(1)
    }
    let addr = data.u32(offset)
    let size = Int(data.u32(offset + 4))
    let fileOff = offset

    print(String(format: "Segment %d: len 0x%05x load 0x%08x file_offs 0x%08x [%@]",
                 i + 1, size, addr, fileOff, memoryType(addr)))

    // Update checksum with segment data
    let dataStart = offset + 8
    let dataEnd = dataStart + size
    guard dataEnd <= data.count else {
        fputs("Error: Segment data exceeds file size\n", stderr)
        exit(1)
    }
    for byte in data[dataStart..<dataEnd] {
        checksumState ^= byte
    }

    offset = dataEnd
}

// Read checksum: align to 16 bytes, read 1 byte
let align = (16 - 1) - (offset % 16)
offset += align
let storedChecksum = data[offset]
offset += 1

let checksumValid = (checksumState == storedChecksum)
print(String(format: "Checksum: %02x (%@)", storedChecksum, checksumValid ? "valid" : "invalid"))

// SHA-256 validation
if appendDigest == 1 && offset + 32 <= data.count {
    let imageData = data.prefix(offset)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    imageData.withUnsafeBytes { ptr in
        _ = CC_SHA256(ptr.baseAddress, CC_LONG(imageData.count), &hash)
    }
    let storedHash = data.subdata(in: offset..<(offset + 32))
    let computedHash = Data(hash)
    let hashValid = (storedHash == computedHash)
    print("Validation Hash: \(hexStr(computedHash)) (\(hashValid ? "valid" : "invalid"))")
}
