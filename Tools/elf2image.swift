// elf2image.swift — ELF to ESP32-C6 flash image converter
// Usage: swift elf2image.swift --flash_mode dio --flash_freq 80m --flash_size 2MB -o out.bin input.elf

import Foundation
import CommonCrypto

// MARK: - Constants

let ESP_IMAGE_MAGIC: UInt8 = 0xE9
let ESP_CHECKSUM_MAGIC: UInt8 = 0xEF
let SEG_HEADER_LEN = 8
let IROM_ALIGN = 65536

let IROM_MAP_START: UInt32 = 0x42000000
let IROM_MAP_END:   UInt32 = 0x42800000
let DROM_MAP_START: UInt32 = 0x42800000
let DROM_MAP_END:   UInt32 = 0x43000000

let IMAGE_CHIP_ID: UInt16 = 13   // ESP32-C6
let WP_PIN_DISABLED: UInt8 = 0xEE

let flashModes: [String: UInt8] = ["qio": 0, "qout": 1, "dio": 2, "dout": 3]
let flashSizes: [String: UInt8] = [
    "1MB": 0x00, "2MB": 0x10, "4MB": 0x20, "8MB": 0x30,
    "16MB": 0x40, "32MB": 0x50, "64MB": 0x60, "128MB": 0x70,
]
let flashFreqs: [String: UInt8] = ["80m": 0x00, "40m": 0x00, "20m": 0x02]

// MARK: - ELF Parser

struct ELFSection {
    let name: String
    let addr: UInt32
    var data: Data
}

struct ELFFile {
    let entrypoint: UInt32
    var sections: [ELFSection]

    init(path: String) throws {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))

        // ELF header (52 bytes for 32-bit)
        guard fileData.count >= 52 else { throw ESPError("ELF file too small") }

        // Magic: 0x7f ELF
        guard fileData[0] == 0x7F, fileData[1] == 0x45, fileData[2] == 0x4C, fileData[3] == 0x46
        else { throw ESPError("Invalid ELF magic") }

        let machine = fileData.readUInt16(at: 18)
        guard machine == 0xF3 else { throw ESPError("Not a RISC-V ELF (e_machine=\(String(machine, radix: 16)))") }

        let entry = fileData.readUInt32(at: 24)
        let shoff = Int(fileData.readUInt32(at: 32))
        let shentsize = Int(fileData.readUInt16(at: 46))
        let shnum = Int(fileData.readUInt16(at: 48))
        let shstrndx = Int(fileData.readUInt16(at: 50))

        guard shentsize == 40 else { throw ESPError("Unexpected section header entry size: \(shentsize)") }
        guard shnum > 0 else { throw ESPError("No section headers") }

        // Read string table section
        let strTabOff = shoff + shstrndx * shentsize
        let strTabSecOff = Int(fileData.readUInt32(at: strTabOff + 16))
        let strTabSecSize = Int(fileData.readUInt32(at: strTabOff + 20))
        let stringTable = fileData.subdata(in: strTabSecOff..<(strTabSecOff + strTabSecSize))

        // Read sections
        let SEC_TYPE_PROGBITS: UInt32 = 0x01
        let SEC_TYPE_INITARRAY: UInt32 = 0x0E
        let SEC_TYPE_FINIARRAY: UInt32 = 0x0F
        let SEC_TYPE_PREINITARRAY: UInt32 = 0x10
        let progTypes: Set<UInt32> = [SEC_TYPE_PROGBITS, SEC_TYPE_INITARRAY, SEC_TYPE_FINIARRAY, SEC_TYPE_PREINITARRAY]

        var result: [ELFSection] = []
        for i in 0..<shnum {
            let off = shoff + i * shentsize
            let nameOff = Int(fileData.readUInt32(at: off))
            let secType = fileData.readUInt32(at: off + 4)
            let lma = fileData.readUInt32(at: off + 12)
            let secOff = Int(fileData.readUInt32(at: off + 16))
            let size = Int(fileData.readUInt32(at: off + 20))

            guard lma != 0, size != 0 else { continue }
            guard progTypes.contains(secType) else { continue }

            let name = stringTable.readCString(at: nameOff)
            var data = fileData.subdata(in: secOff..<(secOff + size))

            // Pad to 4-byte alignment (only for non-zero addr)
            if lma != 0 {
                let pad = (4 - (data.count % 4)) % 4
                if pad > 0 { data.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
            }

            result.append(ELFSection(name: name, addr: lma, data: data))
        }

        self.entrypoint = entry
        self.sections = result
    }
}

// MARK: - Image Builder

func isFlashAddr(_ addr: UInt32) -> Bool {
    (IROM_MAP_START <= addr && addr < IROM_MAP_END) ||
    (DROM_MAP_START <= addr && addr < DROM_MAP_END)
}

func espChecksum(_ data: Data, state: UInt8 = ESP_CHECKSUM_MAGIC) -> UInt8 {
    data.reduce(state) { $0 ^ $1 }
}

func mergeAdjacentSegments(_ sections: [ELFSection]) -> [ELFSection] {
    guard sections.count > 1 else { return sections }

    var result = sections
    var i = result.count - 1
    while i > 0 {
        let prev = result[i - 1]
        let curr = result[i]
        let sameType = isFlashAddr(prev.addr) == isFlashAddr(curr.addr)
        let adjacent = curr.addr == prev.addr + UInt32(prev.data.count)
        if sameType && adjacent {
            result[i - 1].data.append(curr.data)
            result.remove(at: i)
        }
        i -= 1
    }
    return result
}

func buildImage(
    sections: [ELFSection],
    entrypoint: UInt32,
    flashMode: UInt8,
    flashSizeFreq: UInt8
) -> Data {
    var buf = Data()
    var checksum: UInt8 = ESP_CHECKSUM_MAGIC
    var totalSegments: UInt8 = 0

    // Common header (8 bytes)
    buf.append(ESP_IMAGE_MAGIC)
    buf.append(0) // placeholder for segment count
    buf.append(flashMode)
    buf.append(flashSizeFreq)
    buf.appendUInt32(entrypoint)

    // Extended header (16 bytes)
    buf.append(WP_PIN_DISABLED)       // wp_pin
    buf.append(0)                      // clk_drv | q_drv
    buf.append(0)                      // d_drv | cs_drv
    buf.append(0)                      // hd_drv | wp_drv
    buf.appendUInt16(IMAGE_CHIP_ID)   // chip_id
    buf.append(0)                      // min_rev
    buf.appendUInt16(0)               // min_rev_full
    buf.appendUInt16(0xFFFF)          // max_rev_full (default)
    buf.append(contentsOf: [UInt8](repeating: 0, count: 4)) // padding
    buf.append(1)                      // append_digest

    // Split into flash and RAM segments, sorted by address
    var flashSegments = sections.filter { isFlashAddr($0.addr) }.sorted { $0.addr < $1.addr }
    var ramSegments = sections.filter { !isFlashAddr($0.addr) }.sorted { $0.addr < $1.addr }

    // Validate: no two flash segments in the same MMU page
    if flashSegments.count > 1 {
        for i in 1..<flashSegments.count {
            if flashSegments[i].addr / UInt32(IROM_ALIGN) == flashSegments[i-1].addr / UInt32(IROM_ALIGN) {
                fputs("Error: Segments at \(hex(flashSegments[i-1].addr)) and \(hex(flashSegments[i].addr)) in same MMU page\n", stderr)
                exit(1)
            }
        }
    }

    // Calculate alignment data needed for a flash segment
    func getAlignmentDataNeeded(_ segment: ELFSection) -> Int {
        let alignPast = Int(segment.addr % UInt32(IROM_ALIGN)) - SEG_HEADER_LEN
        var padLen = (IROM_ALIGN - (buf.count % IROM_ALIGN)) + alignPast
        if padLen == 0 || padLen == IROM_ALIGN { return 0 }
        padLen -= SEG_HEADER_LEN
        if padLen < 0 { padLen += IROM_ALIGN }
        return padLen
    }

    // Write segment: header (addr, size) + data
    func writeSegment(addr: UInt32, data: Data) {
        buf.appendUInt32(addr)
        buf.appendUInt32(UInt32(data.count))
        buf.append(data)
        checksum = espChecksum(data, state: checksum)
        totalSegments += 1
    }

    // Process flash segments with alignment
    while !flashSegments.isEmpty {
        let segment = flashSegments[0]
        let padLen = getAlignmentDataNeeded(segment)

        if padLen > 0 {
            // Need padding - try to use RAM segment data
            if !ramSegments.isEmpty && padLen > SEG_HEADER_LEN {
                let available = min(padLen, ramSegments[0].data.count)
                let padData = ramSegments[0].data.prefix(available)
                let padAddr = ramSegments[0].addr
                ramSegments[0].data = ramSegments[0].data.suffix(from: ramSegments[0].data.startIndex + available)
                ramSegments[0] = ELFSection(
                    name: ramSegments[0].name,
                    addr: ramSegments[0].addr + UInt32(available),
                    data: ramSegments[0].data
                )
                if ramSegments[0].data.isEmpty {
                    ramSegments.removeFirst()
                }
                writeSegment(addr: padAddr, data: Data(padData))
            } else {
                writeSegment(addr: 0, data: Data(count: padLen))
            }
        } else {
            // Aligned - write flash segment
            assert((buf.count + SEG_HEADER_LEN) % IROM_ALIGN == Int(segment.addr) % IROM_ALIGN,
                   "Alignment check failed at offset \(hex(UInt32(buf.count)))")
            writeSegment(addr: segment.addr, data: segment.data)
            flashSegments.removeFirst()
        }
    }

    // Write remaining RAM segments
    for segment in ramSegments {
        writeSegment(addr: segment.addr, data: segment.data)
    }

    // Append checksum: align to 16-byte boundary, then write checksum byte
    let align = (16 - 1) - (buf.count % 16)
    buf.append(contentsOf: [UInt8](repeating: 0, count: align))
    buf.append(checksum)

    let imageLength = buf.count

    // Update segment count at byte 1
    buf[1] = totalSegments

    // Append SHA-256 digest
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    buf.prefix(imageLength).withUnsafeBytes { ptr in
        _ = CC_SHA256(ptr.baseAddress, CC_LONG(imageLength), &hash)
    }
    buf.append(contentsOf: hash)

    return buf
}

// MARK: - Helpers

struct ESPError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { self.description = msg }
}

func hex(_ v: UInt32) -> String { String(format: "0x%08x", v) }

extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        self.subdata(in: offset..<(offset+2)).withUnsafeBytes { $0.load(as: UInt16.self) }
    }
    func readUInt32(at offset: Int) -> UInt32 {
        self.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.load(as: UInt32.self) }
    }
    func readCString(at offset: Int) -> String {
        var end = offset
        while end < self.count && self[end] != 0 { end += 1 }
        return String(data: self.subdata(in: offset..<end), encoding: .utf8) ?? ""
    }
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

// MARK: - CLI

func printUsage() -> Never {
    fputs("""
    Usage: swift elf2image.swift [options] -o <output.bin> <input.elf>

    Options:
      --flash_mode  <mode>   qio, qout, dio, dout (default: dio)
      --flash_freq  <freq>   80m, 40m, 20m (default: 80m)
      --flash_size  <size>   1MB, 2MB, 4MB, ... (default: 2MB)
      -o <output>            Output file path

    """, stderr)
    exit(1)
}

// Parse arguments
var args = CommandLine.arguments.dropFirst()
var flashModeStr = "dio"
var flashFreqStr = "80m"
var flashSizeStr = "2MB"
var outputPath: String?
var inputPath: String?

while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--flash_mode":
        guard let v = args.first else { printUsage() }
        flashModeStr = v; args = args.dropFirst()
    case "--flash_freq":
        guard let v = args.first else { printUsage() }
        flashFreqStr = v; args = args.dropFirst()
    case "--flash_size":
        guard let v = args.first else { printUsage() }
        flashSizeStr = v; args = args.dropFirst()
    case "-o":
        guard let v = args.first else { printUsage() }
        outputPath = v; args = args.dropFirst()
    default:
        if arg.hasPrefix("-") { printUsage() }
        inputPath = arg
    }
}

guard let inputPath, let outputPath else { printUsage() }
guard let fmVal = flashModes[flashModeStr] else {
    fputs("Error: Unknown flash mode '\(flashModeStr)'\n", stderr); exit(1)
}
guard let fsVal = flashSizes[flashSizeStr] else {
    fputs("Error: Unknown flash size '\(flashSizeStr)'\n", stderr); exit(1)
}
guard let ffVal = flashFreqs[flashFreqStr] else {
    fputs("Error: Unknown flash freq '\(flashFreqStr)'\n", stderr); exit(1)
}

// Process
do {
    let elf = try ELFFile(path: inputPath)
    let merged = mergeAdjacentSegments(elf.sections)

    guard merged.count <= 16 else {
        fputs("Error: Too many segments (\(merged.count), max 16)\n", stderr)
        exit(1)
    }

    let image = buildImage(
        sections: merged,
        entrypoint: elf.entrypoint,
        flashMode: fmVal,
        flashSizeFreq: fsVal + ffVal
    )

    // Create output directory if needed
    let outputDir = (outputPath as NSString).deletingLastPathComponent
    if !outputDir.isEmpty {
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    try image.write(to: URL(fileURLWithPath: outputPath))

    let segCount = merged.filter { isFlashAddr($0.addr) }.count +
                   merged.filter { !isFlashAddr($0.addr) }.count
    print("Wrote \(hex(UInt32(image.count))) bytes to \(outputPath) (\(segCount) sections, entry \(hex(elf.entrypoint)))")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
