// Runtime stubs required by Embedded Swift on bare-metal RISC-V.
//
// These provide the minimal C runtime functions that the Swift
// compiler expects, since we link with -nostdlib.

// MARK: - Linker symbol helper

@inline(__always)
func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
    withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}

// MARK: - Heap Allocation (bump allocator)

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


