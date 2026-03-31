@inline(__always)
private func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
    withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}

@_extern(c, "_sbss") nonisolated(unsafe) var _sbss: UInt8
@_extern(c, "_ebss") nonisolated(unsafe) var _ebss: UInt8

/// Zero the .bss section. Must be called before any code that depends on
/// zero-initialized global variables (following ESP-IDF convention).
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
