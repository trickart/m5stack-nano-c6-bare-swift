// write-flash.swift — Flash writer for ESP32-C6 via serial
// Usage: swift write-flash.swift [-b baud] [-p port]
//        0x0 bootloader.bin 0x8000 partition.bin 0x10000 app.bin

import Foundation
import CommonCrypto
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Constants

let SLIP_END: UInt8     = 0xC0
let SLIP_ESC: UInt8     = 0xDB
let SLIP_ESC_END: UInt8 = 0xDC
let SLIP_ESC_ESC: UInt8 = 0xDD

let ESP_FLASH_BEGIN: UInt8  = 0x02
let ESP_FLASH_DATA: UInt8   = 0x03
let ESP_FLASH_END: UInt8    = 0x04
let ESP_SYNC: UInt8         = 0x08
let ESP_READ_REG: UInt8     = 0x0A
let ESP_SPI_SET_PARAMS: UInt8 = 0x0B
let ESP_SPI_ATTACH: UInt8   = 0x0D
let ESP_CHANGE_BAUD: UInt8  = 0x0F
let ESP_SPI_FLASH_MD5: UInt8 = 0x13

let ESP_CHECKSUM_MAGIC: UInt8 = 0xEF
let FLASH_WRITE_SIZE = 0x400  // 1KB blocks for ROM loader
let FLASH_SECTOR_SIZE = 0x1000

let ERASE_REGION_TIMEOUT_PER_MB: Double = 30.0
let MD5_TIMEOUT_PER_MB: Double = 8.0
let DEFAULT_TIMEOUT: Double = 3.0

let DEFAULT_BAUD: Int = 460800
let INITIAL_BAUD: Int = 115200

// MARK: - SLIP Protocol

func slipEncode(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [SLIP_END]
    for byte in data {
        switch byte {
        case SLIP_END: out.append(contentsOf: [SLIP_ESC, SLIP_ESC_END])
        case SLIP_ESC: out.append(contentsOf: [SLIP_ESC, SLIP_ESC_ESC])
        default: out.append(byte)
        }
    }
    out.append(SLIP_END)
    return out
}

// MARK: - Serial Port

class SerialPort {
    let fd: Int32
    let path: String
    private var readBuffer: [UInt8] = []

    init(path: String, baudRate: Int = INITIAL_BAUD) throws {
        self.path = path
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw ESPError("Cannot open \(path): \(String(cString: strerror(errno)))") }

        // Exclusive access
        if ioctl(fd, TIOCEXCL) != 0 {
            close(fd)
            throw ESPError("Cannot get exclusive access to \(path)")
        }

        // Clear O_NONBLOCK
        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)

        // Configure terminal
        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)

        let speed = speedConstant(baudRate)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        // VMIN=1, VTIME=10 (1 second timeout)
        withUnsafeMutableBytes(of: &options.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 10
        }

        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)
    }

    func setBaudRate(_ rate: Int) {
        var options = termios()
        tcgetattr(fd, &options)
        let speed = speedConstant(rate)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)
        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)
    }

    func setDTR(_ state: Bool) {
        var status: Int32 = 0
        _ = ioctl(fd, TIOCMGET, &status)
        if state { status |= TIOCM_DTR } else { status &= ~TIOCM_DTR }
        _ = ioctl(fd, TIOCMSET, &status)
    }

    func setRTS(_ state: Bool) {
        var status: Int32 = 0
        _ = ioctl(fd, TIOCMGET, &status)
        if state { status |= TIOCM_RTS } else { status &= ~TIOCM_RTS }
        _ = ioctl(fd, TIOCMSET, &status)
    }

    func writeBytes(_ data: [UInt8]) throws {
        var remaining = data[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress!, buf.count)
            }
            if written < 0 {
                throw ESPError("Write failed: \(String(cString: strerror(errno)))")
            }
            remaining = remaining.dropFirst(written)
        }
    }

    func readBulk(maxCount: Int, timeout: TimeInterval) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: maxCount)
        var readfds = fd_set()
        fdZero(&readfds)
        fdSet(fd, &readfds)
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1.0)) * 1_000_000)
        )
        let sel = select(fd + 1, &readfds, nil, nil, &tv)
        guard sel > 0 else { return [] }
        let n = read(fd, &buf, maxCount)
        return n > 0 ? Array(buf.prefix(n)) : []
    }

    func readSlipPacket(timeout: TimeInterval) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        var raw: [UInt8] = []
        var foundStart = false

        // Process any bytes left over from previous reads
        func processBytes(_ bytes: ArraySlice<UInt8>) -> (packet: [UInt8]?, remaining: ArraySlice<UInt8>) {
            for i in bytes.indices {
                let byte = bytes[i]
                if byte == SLIP_END {
                    if foundStart && !raw.isEmpty {
                        // Decode SLIP escapes
                        var decoded: [UInt8] = []
                        decoded.reserveCapacity(raw.count)
                        var j = 0
                        while j < raw.count {
                            if raw[j] == SLIP_ESC && j + 1 < raw.count {
                                switch raw[j + 1] {
                                case SLIP_ESC_END: decoded.append(SLIP_END)
                                case SLIP_ESC_ESC: decoded.append(SLIP_ESC)
                                default: decoded.append(raw[j + 1])
                                }
                                j += 2
                            } else {
                                decoded.append(raw[j])
                                j += 1
                            }
                        }
                        // Save remaining bytes for next call
                        let leftover = bytes[(i + 1)...]
                        return (decoded, leftover)
                    }
                    foundStart = true
                    raw.removeAll(keepingCapacity: true)
                } else if foundStart {
                    raw.append(byte)
                }
            }
            return (nil, bytes[bytes.endIndex...])
        }

        // First, process any buffered data from previous calls
        if !readBuffer.isEmpty {
            let buffered = readBuffer[...]
            readBuffer.removeAll()
            let (packet, remaining) = processBytes(buffered)
            if let packet = packet {
                readBuffer = Array(remaining)
                return packet
            }
        }

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let chunk = readBulk(maxCount: 4096, timeout: min(remaining, 1.0))
            if chunk.isEmpty {
                if Date() >= deadline { break }
                continue
            }

            let (packet, leftover) = processBytes(chunk[...])
            if let packet = packet {
                readBuffer.append(contentsOf: leftover)
                return packet
            }
        }
        throw ESPError("Timeout reading SLIP packet")
    }

    func flush() {
        readBuffer.removeAll()
        tcflush(fd, TCIOFLUSH)
    }

    /// Read and discard all pending data from the serial buffer
    func drain() {
        readBuffer.removeAll()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var readfds = fd_set()
            fdZero(&readfds)
            fdSet(fd, &readfds)
            var tv = timeval(tv_sec: 0, tv_usec: 50_000) // 50ms
            let sel = select(fd + 1, &readfds, nil, nil, &tv)
            guard sel > 0 else { break }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
        }
        tcflush(fd, TCIOFLUSH)
    }

    deinit {
        close(fd)
    }

    private func speedConstant(_ rate: Int) -> speed_t {
        switch rate {
        case 9600:    return speed_t(B9600)
        case 19200:   return speed_t(B19200)
        case 38400:   return speed_t(B38400)
        case 57600:   return speed_t(B57600)
        case 115200:  return speed_t(B115200)
        case 230400:  return speed_t(B230400)
        case 460800:  return speed_t(460800)
        case 921600:  return speed_t(921600)
        default:      return speed_t(rate)
        }
    }
}

// fd_set helpers for select()
func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / (MemoryLayout<Int32>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<Int32>.size * 8)
    withUnsafeMutableBytes(of: &set) { rbp in
        let ptr = rbp.baseAddress!.assumingMemoryBound(to: Int32.self)
        ptr[intOffset] |= Int32(1 << bitOffset)
    }
}

func timeoutPerMB(_ secondsPerMB: Double, _ sizeBytes: Int) -> Double {
    let result = secondsPerMB * (Double(sizeBytes) / 1_000_000.0)
    return max(result, DEFAULT_TIMEOUT)
}

// MARK: - ESP Loader

class ESPLoader {
    let port: SerialPort
    var trace = false

    init(port: SerialPort) {
        self.port = port
    }

    // Send command and receive response.
    // resp_data_len: expected response data length before status bytes.
    // Status bytes are at data[resp_data_len..<resp_data_len+2].
    // ROM bootloaders return 2 additional reserved bytes after status (ignored).
    func command(op: UInt8, data: [UInt8] = [], checksum: UInt32 = 0, timeout: TimeInterval = 3.0, respDataLen: Int = 0) throws -> (value: UInt32, data: [UInt8]) {
        // Build packet: direction(0x00) + op + len(u16le) + checksum(u32le) + data
        var pkt: [UInt8] = [0x00, op]
        pkt.append(UInt8(data.count & 0xFF))
        pkt.append(UInt8((data.count >> 8) & 0xFF))
        pkt.append(UInt8(checksum & 0xFF))
        pkt.append(UInt8((checksum >> 8) & 0xFF))
        pkt.append(UInt8((checksum >> 16) & 0xFF))
        pkt.append(UInt8((checksum >> 24) & 0xFF))
        pkt.append(contentsOf: data)

        if trace {
            let hdr = pkt.prefix(min(24, pkt.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
            fputs("TRACE TX cmd=0x\(String(format: "%02x", op)) len=\(data.count) chk=0x\(String(format: "%08x", checksum)) hdr: \(hdr)...\n", stderr)
        }

        let encoded = slipEncode(pkt)
        try port.writeBytes(encoded)
        tcdrain(port.fd)  // ensure all bytes are transmitted

        // Read response(s)
        for _ in 0..<100 {
            let resp = try port.readSlipPacket(timeout: timeout)
            guard resp.count >= 8 else { continue }
            guard resp[0] == 0x01 else { continue } // direction = response
            guard resp[1] == op else { continue }    // matching command

            let value = UInt32(resp[4]) | (UInt32(resp[5]) << 8) | (UInt32(resp[6]) << 16) | (UInt32(resp[7]) << 24)
            let respData = Array(resp.suffix(from: 8))

            if trace {
                let hdr = resp.prefix(min(24, resp.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                fputs("TRACE RX cmd=0x\(String(format: "%02x", resp[1])) val=0x\(String(format: "%08x", value)) data_len=\(respData.count) hdr: \(hdr)\n", stderr)
            }

            // Status bytes are at data[respDataLen..<respDataLen+2].
            // ROM bootloaders (except ESP8266) return 2 extra reserved
            // bytes after status which must be ignored.
            if respData.count >= respDataLen + 2 {
                let status = respData[respDataLen]
                let error = respData[respDataLen + 1]
                if status != 0 {
                    throw ESPError("Command 0x\(String(format: "%02x", op)) failed: status=\(status) error=\(error)")
                }
            }
            return (value, respData)
        }
        throw ESPError("No valid response for command 0x\(String(format: "%02x", op))")
    }

    // SYNC command
    func sync() throws {
        var syncData: [UInt8] = [0x07, 0x07, 0x12, 0x20]
        syncData.append(contentsOf: [UInt8](repeating: 0x55, count: 32))

        for attempt in 1...5 {
            port.flush()
            do {
                _ = try command(op: ESP_SYNC, data: syncData, timeout: 0.1)
                // Read remaining sync responses
                for _ in 0..<7 {
                    let _ = try? port.readSlipPacket(timeout: 0.1)
                }
                return
            } catch {
                if attempt == 5 { throw error }
                usleep(50_000)
            }
        }
    }

    // Reset into bootloader (USB-JTAG-Serial)
    func resetIntoBootloader() throws {
        port.setRTS(false)
        port.setDTR(false)
        usleep(100_000)

        port.setDTR(true)
        port.setRTS(false)
        usleep(100_000)

        port.setRTS(true)
        port.setDTR(false)
        port.setRTS(true)
        usleep(100_000)

        port.setDTR(false)
        port.setRTS(false)
        usleep(100_000)

        port.flush()
    }

    // Connect to bootloader
    func connect() throws {
        print("Connecting...", terminator: "")
        fflush(stdout)

        for attempt in 1...10 {
            do {
                try resetIntoBootloader()
                try sync()
                print(" done.")
                return
            } catch {
                print(".", terminator: "")
                fflush(stdout)
                if attempt == 10 { print(""); throw ESPError("Failed to connect to ESP32-C6") }
            }
        }
    }

    // Read a 32-bit register
    func readReg(addr: UInt32) throws -> UInt32 {
        var data = [UInt8](repeating: 0, count: 4)
        packUInt32(&data, offset: 0, value: addr)
        let (value, _) = try command(op: ESP_READ_REG, data: data)
        return value
    }

    // Read flash manufacturer/device ID via SPI
    func flashId() throws -> UInt32 {
        // SPI_FLASH_RDID command via SPIFLASH peripheral
        // For ESP32-C6: SPI_MEM_C base = 0x60002000
        let spiCmd = try readReg(addr: 0x60002000 + 0x00)  // current state
        _ = spiCmd // not needed
        // Use flash_id approach: read via SPI registers
        // Actually, use the FLASH_ID stub approach via READ_REG on specific addresses
        // This is chip-specific; simplified version below
        return 0 // will use for diagnostics only
    }

    // SPI attach (required for ROM loader on non-ESP32 chips)
    func spiAttach() throws {
        // ROM loader: 4 bytes hspi_arg + 4 bytes (is_legacy + reserved)
        let data = [UInt8](repeating: 0, count: 8)
        _ = try command(op: ESP_SPI_ATTACH, data: data)
    }

    // Set SPI flash parameters (tell ROM the flash chip config)
    func flashSetParameters(size: Int) throws {
        var data = [UInt8](repeating: 0, count: 24)
        packUInt32(&data, offset: 0, value: 0)                  // fl_id
        packUInt32(&data, offset: 4, value: UInt32(size))       // total_size
        packUInt32(&data, offset: 8, value: 64 * 1024)          // block_size
        packUInt32(&data, offset: 12, value: 4 * 1024)          // sector_size
        packUInt32(&data, offset: 16, value: 256)               // page_size
        packUInt32(&data, offset: 20, value: 0xFFFF)            // status_mask
        _ = try command(op: ESP_SPI_SET_PARAMS, data: data)
    }

    // Change baud rate
    func changeBaud(_ newBaud: Int) throws {
        var data = [UInt8](repeating: 0, count: 8)
        data[0] = UInt8(newBaud & 0xFF)
        data[1] = UInt8((newBaud >> 8) & 0xFF)
        data[2] = UInt8((newBaud >> 16) & 0xFF)
        data[3] = UInt8((newBaud >> 24) & 0xFF)
        _ = try command(op: ESP_CHANGE_BAUD, data: data)
        port.setBaudRate(newBaud)
        usleep(50_000)
        port.flush()
    }

    // Flash begin - ROM loader erases upfront, needs longer timeout
    // ESP32-C6 ROM requires 5th param (encrypted flag) since SUPPORTS_ENCRYPTED_FLASH=True
    func flashBegin(size: Int, offset: Int) throws -> Int {
        let numBlocks = (size + FLASH_WRITE_SIZE - 1) / FLASH_WRITE_SIZE
        let eraseSize = size

        var data = [UInt8](repeating: 0, count: 20)
        packUInt32(&data, offset: 0, value: UInt32(eraseSize))
        packUInt32(&data, offset: 4, value: UInt32(numBlocks))
        packUInt32(&data, offset: 8, value: UInt32(FLASH_WRITE_SIZE))
        packUInt32(&data, offset: 12, value: UInt32(offset))
        packUInt32(&data, offset: 16, value: 0)  // not encrypted

        // ROM performs erase upfront - timeout scales with size
        let timeout = timeoutPerMB(ERASE_REGION_TIMEOUT_PER_MB, eraseSize)
        _ = try command(op: ESP_FLASH_BEGIN, data: data, timeout: timeout)
        return numBlocks
    }

    // Flash data block - ROM writes to flash before ACKing
    func flashBlock(data blockData: [UInt8], seq: Int) throws {
        // Pad the last block to FLASH_WRITE_SIZE with 0xFF
        var padded = blockData
        if padded.count < FLASH_WRITE_SIZE {
            padded.append(contentsOf: [UInt8](repeating: 0xFF, count: FLASH_WRITE_SIZE - padded.count))
        }

        var header = [UInt8](repeating: 0, count: 16)
        packUInt32(&header, offset: 0, value: UInt32(padded.count))
        packUInt32(&header, offset: 4, value: UInt32(seq))
        packUInt32(&header, offset: 8, value: 0)
        packUInt32(&header, offset: 12, value: 0)

        let payload = header + padded
        let chk = UInt32(espChecksum(padded))
        // ROM writes block to flash before ACK - timeout scales with block size
        let timeout = timeoutPerMB(40.0, padded.count) // ERASE_WRITE_TIMEOUT_PER_MB = 40
        _ = try command(op: ESP_FLASH_DATA, data: payload, checksum: chk, timeout: timeout)
    }

    // Flash end
    func flashEnd(reboot: Bool) throws {
        var data = [UInt8](repeating: 0, count: 4)
        packUInt32(&data, offset: 0, value: reboot ? 0 : 1)
        _ = try command(op: ESP_FLASH_END, data: data, timeout: DEFAULT_TIMEOUT)
    }

    // SPI Flash MD5 - ROM returns 32 hex chars (ASCII)
    func flashMD5(addr: Int, size: Int) throws -> String {
        var data = [UInt8](repeating: 0, count: 16)
        packUInt32(&data, offset: 0, value: UInt32(addr))
        packUInt32(&data, offset: 4, value: UInt32(size))
        packUInt32(&data, offset: 8, value: 0)
        packUInt32(&data, offset: 12, value: 0)

        let timeout = timeoutPerMB(MD5_TIMEOUT_PER_MB, size)
        let (_, respData) = try command(op: ESP_SPI_FLASH_MD5, data: data, timeout: timeout, respDataLen: 32)
        // ROM loader returns 32 hex chars (ASCII) + 2 status + 2 reserved
        if respData.count >= 32 {
            let hexBytes = Array(respData.prefix(32))
            return String(bytes: hexBytes, encoding: .ascii) ?? ""
        }
        throw ESPError("Unexpected MD5 response length: \(respData.count)")
    }
}

// MARK: - Helpers

struct ESPError: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

func packUInt32(_ buf: inout [UInt8], offset: Int, value: UInt32) {
    buf[offset]     = UInt8(value & 0xFF)
    buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    buf[offset + 2] = UInt8((value >> 16) & 0xFF)
    buf[offset + 3] = UInt8((value >> 24) & 0xFF)
}

func espChecksum(_ data: [UInt8]) -> UInt8 {
    data.reduce(ESP_CHECKSUM_MAGIC) { $0 ^ $1 }
}

func md5Hex(_ data: Data) -> String {
    var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    data.withUnsafeBytes { ptr in
        _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &hash)
    }
    return hash.map { String(format: "%02x", $0) }.joined()
}

func autoDetectPort() -> String? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return nil }
    let ports = entries.filter { $0.hasPrefix("cu.usbmodem") }.sorted()
    return ports.first.map { "/dev/\($0)" }
}

// MARK: - Flash writing

func writeFlash(loader: ESPLoader, regions: [(offset: Int, path: String)]) throws {
    for (offset, path) in regions {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        // Pad to 4 bytes
        var padded = fileData
        let pad = (4 - (padded.count % 4)) % 4
        if pad > 0 { padded.append(contentsOf: [UInt8](repeating: 0xFF, count: pad)) }

        let numBlocks = try loader.flashBegin(size: padded.count, offset: offset)
        let fileName = (path as NSString).lastPathComponent

        print("Writing \(fileName) at 0x\(String(format: "%05x", offset)) (\(padded.count) bytes)...")

        for seq in 0..<numBlocks {
            let start = seq * FLASH_WRITE_SIZE
            let end = min(start + FLASH_WRITE_SIZE, padded.count)
            let block = Array(padded[start..<end])
            try loader.flashBlock(data: block, seq: seq)

            let pct = 100 * (seq + 1) / numBlocks
            print("\r  Writing... \(pct)%", terminator: "")
            fflush(stdout)
        }
        print("")

        // Verify MD5
        let expectedMD5 = md5Hex(padded)
        let deviceMD5 = try loader.flashMD5(addr: offset, size: padded.count)
        if expectedMD5 == deviceMD5 {
            print("  Verified (MD5: \(expectedMD5))")
        } else {
            throw ESPError("MD5 mismatch for \(fileName): expected \(expectedMD5), got \(deviceMD5)")
        }

        // Drain serial buffer before next region
        usleep(50_000)
        loader.port.drain()
    }
}

// MARK: - CLI

func printUsage() -> Never {
    fputs("""
    Usage: swift write-flash.swift [options] <addr1> <file1> [<addr2> <file2> ...]

    Options:
      -b <baud>              Baud rate (default: 460800)
      -p <port>              Serial port (default: auto-detect /dev/cu.usbmodem*)
      --flash_mode <mode>    qio, qout, dio, dout (for header patching, optional)
      --flash_size <size>    Flash size (for header patching, optional)
      --flash_freq <freq>    Flash frequency (for header patching, optional)

    Example:
      swift write-flash.swift 0x0 bootloader.bin 0x8000 partition.bin 0x10000 app.bin

    """, stderr)
    exit(1)
}

var argSlice = CommandLine.arguments.dropFirst()
var baudRate = DEFAULT_BAUD
var portPath: String?
var enableTrace = false
var regions: [(offset: Int, path: String)] = []

// Parse named options
while let arg = argSlice.first, arg.hasPrefix("-") {
    argSlice = argSlice.dropFirst()
    switch arg {
    case "-b":
        guard let v = argSlice.first, let b = Int(v) else { printUsage() }
        baudRate = b; argSlice = argSlice.dropFirst()
    case "-p":
        guard let v = argSlice.first else { printUsage() }
        portPath = v; argSlice = argSlice.dropFirst()
    case "--trace":
        enableTrace = true
    case "--flash_mode", "--flash_size", "--flash_freq":
        guard argSlice.first != nil else { printUsage() }
        argSlice = argSlice.dropFirst()
    case "--before", "--after":
        guard argSlice.first != nil else { printUsage() }
        argSlice = argSlice.dropFirst()
    default:
        printUsage()
    }
}

// Parse address/file pairs
let positional = Array(argSlice)
guard positional.count >= 2, positional.count % 2 == 0 else { printUsage() }
for i in stride(from: 0, to: positional.count, by: 2) {
    guard let offset = Int(positional[i].hasPrefix("0x") || positional[i].hasPrefix("0X")
        ? String(positional[i].dropFirst(2))
        : positional[i], radix: 16) else {
        fputs("Error: Invalid address '\(positional[i])'\n", stderr)
        exit(1)
    }
    let filePath = positional[i + 1]
    guard FileManager.default.fileExists(atPath: filePath) else {
        fputs("Error: File not found '\(filePath)'\n", stderr)
        exit(1)
    }
    regions.append((offset: offset, path: filePath))
}

guard !regions.isEmpty else { printUsage() }

// Auto-detect port if needed
if portPath == nil {
    portPath = autoDetectPort()
}
guard let portPath else {
    fputs("Error: No serial port found. Use -p to specify.\n", stderr)
    exit(1)
}

// Main flow
do {
    print("Serial port: \(portPath)")
    let port = try SerialPort(path: portPath, baudRate: INITIAL_BAUD)
    let loader = ESPLoader(port: port)

    loader.trace = enableTrace
    try loader.connect()

    // Verify communication: read UART_DATE register
    let uartDate = try loader.readReg(addr: 0x60000000 + 0x78) // UART0 date reg
    print("Chip register read OK (UART_DATE: 0x\(String(format: "%08x", uartDate)))")

    // Change to higher baud rate (before SPI attach, same order as esptool.py)
    if baudRate != INITIAL_BAUD {
        print("Changing baud rate to \(baudRate)...")
        try loader.changeBaud(baudRate)

        // Verify communication still works after baud change
        let check = try loader.readReg(addr: 0x60000000 + 0x78)
        if check != uartDate {
            print("WARNING: Register read mismatch after baud change: 0x\(String(format: "%08x", check)) (expected 0x\(String(format: "%08x", uartDate)))")
            print("Baud rate change may have failed. Trying without baud change...")
            // Reset and reconnect at original baud
            port.setBaudRate(INITIAL_BAUD)
            port.flush()
            try loader.resetIntoBootloader()
            try loader.sync()
            baudRate = INITIAL_BAUD
        }
    }

    // Enable SPI flash (required for ROM loader on ESP32-C6)
    print("Enabling default SPI flash mode...")
    try loader.spiAttach()

    // Configure flash parameters
    print("Configuring flash size...")
    try loader.flashSetParameters(size: 2 * 1024 * 1024)  // 2MB

    try writeFlash(loader: loader, regions: regions)

    // Hard reset
    print("Hard resetting via RTS pin...")
    port.setRTS(true)
    usleep(100_000)
    port.setRTS(false)

    print("Done.")
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
