// Generate ESP32 partition table binary.
// Usage: swift Tools/gen-partition-table.swift -o partition-table.bin

import Foundation

// MARK: - MD5 (RFC 1321)

func md5Digest(_ data: Data) -> [UInt8] {
    // Per-round left rotate amounts
    let s: [UInt32] = [
        7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
        5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
        4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
        6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
    ]
    // Precomputed T[i] = floor(2^32 * abs(sin(i+1)))
    let k: [UInt32] = [
        0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,
        0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
        0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,
        0x6b901122,0xfd987193,0xa679438e,0x49b40821,
        0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,
        0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
        0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,
        0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
        0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,
        0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
        0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,
        0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
        0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,
        0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
        0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,
        0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391,
    ]

    // Pre-processing: padding
    var msg = [UInt8](data)
    let originalLen = msg.count
    msg.append(0x80)
    while msg.count % 64 != 56 {
        msg.append(0)
    }
    // Append original length in bits as 64-bit little-endian
    let bitLen = UInt64(originalLen) &* 8
    for i in 0..<8 {
        msg.append(UInt8(truncatingIfNeeded: bitLen >> (i * 8)))
    }

    // Initialize hash values
    var a0: UInt32 = 0x67452301
    var b0: UInt32 = 0xefcdab89
    var c0: UInt32 = 0x98badcfe
    var d0: UInt32 = 0x10325476

    // Process each 64-byte chunk
    for chunkStart in stride(from: 0, to: msg.count, by: 64) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let offset = chunkStart + i * 4
            m[i] = UInt32(msg[offset])
                | (UInt32(msg[offset+1]) << 8)
                | (UInt32(msg[offset+2]) << 16)
                | (UInt32(msg[offset+3]) << 24)
        }

        var a = a0, b = b0, c = c0, d = d0

        for i in 0..<64 {
            var f: UInt32
            var g: Int
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = i
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 &* i &+ 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 &* i &+ 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 &* i) % 16
            }
            f = f &+ a &+ k[i] &+ m[g]
            a = d
            d = c
            c = b
            b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
        }

        a0 = a0 &+ a
        b0 = b0 &+ b
        c0 = c0 &+ c
        d0 = d0 &+ d
    }

    // Produce the 16-byte digest
    var result = [UInt8](repeating: 0, count: 16)
    for (i, val) in [a0, b0, c0, d0].enumerated() {
        result[i*4]   = UInt8(truncatingIfNeeded: val)
        result[i*4+1] = UInt8(truncatingIfNeeded: val >> 8)
        result[i*4+2] = UInt8(truncatingIfNeeded: val >> 16)
        result[i*4+3] = UInt8(truncatingIfNeeded: val >> 24)
    }
    return result
}

// MARK: - Partition Table Format

let PARTITION_MAGIC: [UInt8] = [0xAA, 0x50]
let MD5_MAGIC: [UInt8] = [0xEB, 0xEB]
let PARTITION_TABLE_SIZE = 0xC00  // 3072 bytes

struct PartitionEntry {
    let type: UInt8
    let subtype: UInt8
    let offset: UInt32
    let size: UInt32
    let label: String
    let flags: UInt32

    func toBinary() -> Data {
        var data = Data(capacity: 32)
        data.append(contentsOf: PARTITION_MAGIC)
        data.append(type)
        data.append(subtype)
        data.appendUInt32(offset)
        data.appendUInt32(size)
        // Label: 16 bytes, null-padded
        var labelBytes = [UInt8](label.utf8)
        labelBytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - labelBytes.count))
        data.append(contentsOf: labelBytes.prefix(16))
        data.appendUInt32(flags)
        return data
    }
}

// MARK: - Default Partition Layout

let partitions: [PartitionEntry] = [
    PartitionEntry(type: 0x01, subtype: 0x02, offset: 0x9000,  size: 0x6000,   label: "nvs",      flags: 0),
    PartitionEntry(type: 0x01, subtype: 0x01, offset: 0xF000,  size: 0x1000,   label: "phy_init", flags: 0),
    PartitionEntry(type: 0x00, subtype: 0x00, offset: 0x10000, size: 0x100000, label: "factory",  flags: 0),
]

// MARK: - Generate

func generatePartitionTable() -> Data {
    // Serialize all partition entries
    var entries = Data()
    for p in partitions {
        entries.append(p.toBinary())
    }

    // MD5 entry: magic + 14x 0xFF + 16-byte digest
    let digest = md5Digest(entries)
    var md5Entry = Data(capacity: 32)
    md5Entry.append(contentsOf: MD5_MAGIC)
    md5Entry.append(contentsOf: [UInt8](repeating: 0xFF, count: 14))
    md5Entry.append(contentsOf: digest)

    var result = Data(capacity: PARTITION_TABLE_SIZE)
    result.append(entries)
    result.append(md5Entry)

    // Pad to PARTITION_TABLE_SIZE with 0xFF
    let remaining = PARTITION_TABLE_SIZE - result.count
    if remaining > 0 {
        result.append(contentsOf: [UInt8](repeating: 0xFF, count: remaining))
    }

    return result
}

// MARK: - Data Helpers

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - CLI

var outputPath = "partition-table.bin"

var args = CommandLine.arguments.dropFirst()
while let arg = args.first {
    args = args.dropFirst()
    if arg == "-o", let next = args.first {
        outputPath = next
        args = args.dropFirst()
    }
}

let data = generatePartitionTable()

do {
    try data.write(to: URL(fileURLWithPath: outputPath))
    print("Partition table written to \(outputPath) (\(data.count) bytes)")
    print("  Entries: \(partitions.count)")
    for p in partitions {
        let typeStr = p.type == 0x00 ? "app" : "data"
        print("    \(p.label): \(typeStr), offset=0x\(String(p.offset, radix: 16)), size=0x\(String(p.size, radix: 16))")
    }
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
