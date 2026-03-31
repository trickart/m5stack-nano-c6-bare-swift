// Bump allocator for Embedded Swift on bare-metal RISC-V.
//
// Provides posix_memalign and free stubs required by the Swift runtime
// when linking with -nostdlib. The heap region is defined by _heap_start
// and _heap_end linker symbols.

@inline(__always)
func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
    withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}

@_extern(c, "_heap_start") nonisolated(unsafe) var _heap_start: UInt8
@_extern(c, "_heap_end") nonisolated(unsafe) var _heap_end: UInt8

/// Current top of the heap (grows upward).
nonisolated(unsafe) var heapPointer: UInt = 0

@c(posix_memalign)
func posixMemalign(
    _ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: Int,
    _ size: Int
) -> Int32 {
    if heapPointer == 0 {
        heapPointer = linkerSymbolAddress(&_heap_start)
    }

    // Align up
    let mask = UInt(alignment) &- 1
    heapPointer = (heapPointer &+ mask) & ~mask

    let heapEnd = linkerSymbolAddress(&_heap_end)
    if heapPointer &+ UInt(size) > heapEnd {
        return 12 // ENOMEM
    }

    memptr.pointee = UnsafeMutableRawPointer(bitPattern: heapPointer)
    heapPointer &+= UInt(size)
    return 0
}

@c(free)
func freeStub(_ ptr: UnsafeMutableRawPointer?) {
    // No-op: bump allocator never frees.
}
