// Runtime stubs required by Embedded Swift on bare-metal RISC-V.
// Minimal version for bootloader (no heap allocation needed).

@inline(__always)
func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
    withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}

// MARK: - Heap Allocation (bump allocator)

@_extern(c, "_heap_start") nonisolated(unsafe) var _heap_start: UInt8
@_extern(c, "_heap_end") nonisolated(unsafe) var _heap_end: UInt8

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
func freeStub(_ ptr: UnsafeMutableRawPointer?) {}

// MARK: - Memory Operations

@c(memset)
@inline(never)
func memsetStub(
    _ dest: UnsafeMutableRawPointer,
    _ value: Int32,
    _ count: Int
) -> UnsafeMutableRawPointer {
    let byte = UInt8(truncatingIfNeeded: value)
    let ptr = dest.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        ptr[i] = byte
    }
    return dest
}

@c(memcpy)
@inline(never)
func memcpyStub(
    _ dest: UnsafeMutableRawPointer,
    _ src: UnsafeRawPointer,
    _ count: Int
) -> UnsafeMutableRawPointer {
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let s = src.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        d[i] = s[i]
    }
    return dest
}

@c(memmove)
@inline(never)
func memmoveStub(
    _ dest: UnsafeMutableRawPointer,
    _ src: UnsafeRawPointer,
    _ count: Int
) -> UnsafeMutableRawPointer {
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let s = src.assumingMemoryBound(to: UInt8.self)
    if UInt(bitPattern: d) < UInt(bitPattern: s) {
        for i in 0..<count { d[i] = s[i] }
    } else if UInt(bitPattern: d) > UInt(bitPattern: s) {
        var i = count
        while i > 0 { i &-= 1; d[i] = s[i] }
    }
    return dest
}
