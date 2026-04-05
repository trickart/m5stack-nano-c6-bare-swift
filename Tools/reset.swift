// reset.swift — Hard reset ESP32-C3 via USB-JTAG-Serial DTR/RTS glue logic
// Usage: swift reset.swift [-p /dev/cu.usbmodemXXX]
//
// ESP32-C3 USB-JTAG-Serial glue logic:
//   chip_reset = RTS & ~DTR
//   GPIO9(boot) = DTR & ~RTS
// DTR must be explicitly deasserted for RTS toggle to trigger reset.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

func autoDetectPort() -> String? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return nil }
    let ports = entries.filter { $0.hasPrefix("cu.usbmodem") }.sorted()
    return ports.first.map { "/dev/\($0)" }
}

var portPath: String?
var args = CommandLine.arguments.dropFirst()
while let arg = args.first {
    if arg == "-p", let v = args.dropFirst().first {
        portPath = v
        args = args.dropFirst(2)
    } else {
        args = args.dropFirst()
    }
}

if portPath == nil { portPath = autoDetectPort() }
guard let portPath else {
    fputs("Error: No serial port found. Use -p to specify.\n", stderr)
    exit(1)
}

let fd = open(portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
guard fd >= 0 else {
    fputs("Error: Cannot open \(portPath)\n", stderr)
    exit(1)
}

// Clear O_NONBLOCK for reliable ioctl
var flags = fcntl(fd, F_GETFL)
flags &= ~O_NONBLOCK
_ = fcntl(fd, F_SETFL, flags)

// Configure terminal for raw mode
var options = termios()
tcgetattr(fd, &options)
cfmakeraw(&options)
tcsetattr(fd, TCSANOW, &options)

func setDTR(_ fd: Int32, _ state: Bool) {
    var status: Int32 = 0
    _ = ioctl(fd, TIOCMGET, &status)
    if state { status |= TIOCM_DTR } else { status &= ~TIOCM_DTR }
    _ = ioctl(fd, TIOCMSET, &status)
}

func setRTS(_ fd: Int32, _ state: Bool) {
    var status: Int32 = 0
    _ = ioctl(fd, TIOCMGET, &status)
    if state { status |= TIOCM_RTS } else { status &= ~TIOCM_RTS }
    _ = ioctl(fd, TIOCMSET, &status)
}

// Hard reset sequence for USB-JTAG-Serial:
// chip_reset = RTS & ~DTR, so DTR must be LOW for RTS to trigger reset
print("Hard resetting via USB-JTAG-Serial (\(portPath))...")
setDTR(fd, false)
setRTS(fd, true)
usleep(200_000)
setRTS(fd, false)
close(fd)
print("Done.")
