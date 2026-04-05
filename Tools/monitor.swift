// monitor.swift — Serial monitor for ESP32-C3 USB-JTAG output
// Usage: swift monitor.swift [/dev/cu.usbmodemXXX]

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Port Detection

func autoDetectPort() -> String? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return nil }
    let ports = entries.filter { $0.hasPrefix("cu.usbmodem") }.sorted()
    return ports.first.map { "/dev/\($0)" }
}

// MARK: - fd_set helpers

func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / (MemoryLayout<Int32>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<Int32>.size * 8)
    withUnsafeMutableBytes(of: &set) { buf in
        let ptr = buf.baseAddress!.assumingMemoryBound(to: Int32.self)
        ptr[intOffset] |= Int32(1 << bitOffset)
    }
}

func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    let intOffset = Int(fd) / (MemoryLayout<Int32>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<Int32>.size * 8)
    return withUnsafeMutableBytes(of: &set) { buf in
        let ptr = buf.baseAddress!.assumingMemoryBound(to: Int32.self)
        return ptr[intOffset] & Int32(1 << bitOffset) != 0
    }
}

// MARK: - Terminal State

var originalTermios = termios()
var serialFd: Int32 = -1

func restoreAndExit(_ sig: Int32) {
    if serialFd >= 0 {
        close(serialFd)
    }
    // Restore stdin terminal settings
    tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
    print("\nDisconnected.")
    exit(0)
}

// MARK: - Main

let portPath: String
if CommandLine.arguments.count > 1 {
    portPath = CommandLine.arguments[1]
} else if let detected = autoDetectPort() {
    portPath = detected
} else {
    fputs("Error: No serial port found. Pass port path as argument.\n", stderr)
    exit(1)
}

// Open serial port
let fd = open(portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
guard fd >= 0 else {
    fputs("Error: Cannot open \(portPath): \(String(cString: strerror(errno)))\n", stderr)
    exit(1)
}
serialFd = fd

// Exclusive access
guard ioctl(fd, TIOCEXCL) == 0 else {
    fputs("Error: Cannot get exclusive access to \(portPath)\n", stderr)
    close(fd)
    exit(1)
}

// Clear O_NONBLOCK
var flags = fcntl(fd, F_GETFL)
flags &= ~O_NONBLOCK
_ = fcntl(fd, F_SETFL, flags)

// Configure serial port for raw mode
var serialOptions = termios()
tcgetattr(fd, &serialOptions)
cfmakeraw(&serialOptions)
let speed = speed_t(B115200)
cfsetispeed(&serialOptions, speed)
cfsetospeed(&serialOptions, speed)
withUnsafeMutableBytes(of: &serialOptions.c_cc) { cc in
    cc[Int(VMIN)] = 1
    cc[Int(VTIME)] = 1
}
tcsetattr(fd, TCSANOW, &serialOptions)
tcflush(fd, TCIOFLUSH)

// Save and configure stdin for raw mode (pass keystrokes through)
tcgetattr(STDIN_FILENO, &originalTermios)
var rawStdin = originalTermios
cfmakeraw(&rawStdin)
tcsetattr(STDIN_FILENO, TCSANOW, &rawStdin)

// Setup signal handler for clean exit
signal(SIGINT, restoreAndExit)
signal(SIGTERM, restoreAndExit)

print("--- Monitor on \(portPath) (Ctrl+C to exit) ---\r")

// Main loop: multiplex stdin and serial port with select()
var buf = [UInt8](repeating: 0, count: 4096)
while true {
    var readfds = fd_set()
    fdZero(&readfds)
    fdSet(fd, &readfds)
    fdSet(STDIN_FILENO, &readfds)

    let maxfd = max(fd, STDIN_FILENO) + 1
    let sel = select(maxfd, &readfds, nil, nil, nil)
    if sel < 0 {
        if errno == EINTR { continue }
        break
    }

    // Data from serial port -> stdout
    if fdIsSet(fd, &readfds) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        _ = write(STDOUT_FILENO, &buf, n)
    }

    // Data from stdin -> serial port
    if fdIsSet(STDIN_FILENO, &readfds) {
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n <= 0 { break }
        // Detect Ctrl+C (0x03) and exit
        if buf.prefix(n).contains(0x03) {
            restoreAndExit(0)
        }
        _ = write(fd, &buf, n)
    }
}

restoreAndExit(0)
