// Free-list heap allocator for Embedded Swift on bare-metal RISC-V.
//
// Provides posix_memalign and free required by the Swift runtime
// when linking with -nostdlib. Uses boundary tags (header + footer)
// for O(1) coalescing of adjacent free blocks. First-fit allocation
// with block splitting.
//
// The heap region is defined by _heap_start and _heap_end linker symbols.

// MARK: - Linker symbols

@inline(__always)
func linkerSymbolAddress(_ symbol: inout UInt8) -> UInt {
    withUnsafePointer(to: &symbol) { UInt(bitPattern: $0) }
}

@_extern(c, "_heap_start") nonisolated(unsafe) var _heap_start: UInt8
@_extern(c, "_heap_end") nonisolated(unsafe) var _heap_end: UInt8

// MARK: - Constants (computed properties to avoid lazy global initialization)

/// Size of the block header (just the `size` field).
@inline(__always) var headerSize: UInt { 4 }
/// Size of the block footer (copy of `size`).
@inline(__always) var footerSize: UInt { 4 }
/// Minimum block size: header(4) + nextFree(4) + pad(4) + footer(4) = 16.
@inline(__always) var minBlock: UInt { 16 }
/// Bit 0 of the size field indicates the block is in use.
@inline(__always) var usedBit: UInt { 1 }

// MARK: - Global state

/// Head of the explicit free list (address of first free block, 0 = empty).
nonisolated(unsafe) var freeListHead: UInt = 0
/// Cached heap boundaries.
nonisolated(unsafe) var heapStart: UInt = 0
nonisolated(unsafe) var heapEnd: UInt = 0

// MARK: - Helpers

@inline(__always)
func load(_ addr: UInt) -> UInt {
    UnsafePointer<UInt>(bitPattern: addr)!.pointee
}

@inline(__always)
func store(_ addr: UInt, _ value: UInt) {
    UnsafeMutablePointer<UInt>(bitPattern: addr)!.pointee = value
}

@inline(__always)
func alignUp(_ value: UInt, _ alignment: UInt) -> UInt {
    let mask = alignment &- 1
    return (value &+ mask) & ~mask
}

/// Remove `block` from the explicit free list.
func removeFromFreeList(_ block: UInt) {
    var prev: UInt = 0
    var curr = freeListHead
    while curr != 0 {
        if curr == block {
            let next = load(curr &+ headerSize) // nextFree
            if prev == 0 {
                freeListHead = next
            } else {
                store(prev &+ headerSize, next)
            }
            return
        }
        prev = curr
        curr = load(curr &+ headerSize)
    }
}

/// One-time heap initialization: create a single free block spanning the
/// entire heap.
func initHeap() {
    heapStart = alignUp(linkerSymbolAddress(&_heap_start), 4)
    heapEnd = linkerSymbolAddress(&_heap_end)
    let totalSize = heapEnd &- heapStart
    // size (free, bit 0 = 0)
    store(heapStart, totalSize)
    // nextFree = 0 (no other free block)
    store(heapStart &+ headerSize, 0)
    // footer
    store(heapStart &+ totalSize &- footerSize, totalSize)
    freeListHead = heapStart
}

// MARK: - Public API

@c(posix_memalign)
func posixMemalign(
    _ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: Int,
    _ size: Int
) -> Int32 {
    if heapStart == 0 {
        initHeap()
    }

    let align = max(UInt(alignment), 4)
    let requestSize = UInt(size)

    var prev: UInt = 0
    var curr = freeListHead

    while curr != 0 {
        let blockSize = load(curr)

        // Where the user pointer would land.
        let bodyStart = curr &+ headerSize
        var userPtr = alignUp(bodyStart, align)

        // If userPtr != bodyStart we need 4 bytes for a back-pointer.
        // Ensure there is room between bodyStart and userPtr for it.
        if userPtr != bodyStart && (userPtr &- bodyStart) < 4 {
            userPtr = alignUp(bodyStart &+ 4, align)
        }

        var needed = (userPtr &- curr) &+ requestSize &+ footerSize
        needed = alignUp(needed, 4)  // Block sizes must be 4-byte aligned
        if needed < minBlock {
            needed = minBlock
        }

        if blockSize >= needed {
            let remainder = blockSize &- needed

            if remainder >= minBlock {
                // Split: create a new free block after the allocated portion.
                let newBlock = curr &+ needed
                store(newBlock, remainder)
                store(newBlock &+ headerSize, load(curr &+ headerSize)) // inherit nextFree
                store(newBlock &+ remainder &- footerSize, remainder)
                // Update free list to replace curr with newBlock.
                if prev == 0 {
                    freeListHead = newBlock
                } else {
                    store(prev &+ headerSize, newBlock)
                }
            } else {
                // Use the entire block.
                needed = blockSize
                let next = load(curr &+ headerSize)
                if prev == 0 {
                    freeListHead = next
                } else {
                    store(prev &+ headerSize, next)
                }
            }

            // Mark allocated (set used bit in header and footer).
            store(curr, needed | usedBit)
            store(curr &+ needed &- footerSize, needed | usedBit)

            // Write back-pointer if user pointer is offset from bodyStart.
            if userPtr != bodyStart {
                store(userPtr &- 4, curr)
            }

            memptr.pointee = UnsafeMutableRawPointer(bitPattern: userPtr)
            return 0
        }

        prev = curr
        curr = load(curr &+ headerSize)
    }

    return 12 // ENOMEM
}

@c(free)
func freeBlock(_ ptr: UnsafeMutableRawPointer?) {
    guard let ptr else { return }

    let ptrAddr = UInt(bitPattern: ptr)

    // Locate the block header.
    // If (ptrAddr - 4) holds a value with bit 0 set, it is the size field
    // itself (header is at ptrAddr - 4). Otherwise it is a back-pointer
    // to the header (used when the user pointer was offset for alignment).
    let word = load(ptrAddr &- 4)
    let blockAddr: UInt
    if word & usedBit != 0 {
        blockAddr = ptrAddr &- headerSize
    } else {
        blockAddr = word
    }

    var blockSize = load(blockAddr) & ~usedBit

    // Coalesce with the next adjacent block.
    let nextBlock = blockAddr &+ blockSize
    if nextBlock < heapEnd {
        let nextSize = load(nextBlock)
        if nextSize & usedBit == 0 {
            removeFromFreeList(nextBlock)
            blockSize &+= nextSize
        }
    }

    // Coalesce with the previous adjacent block.
    if blockAddr > heapStart {
        let prevFooter = load(blockAddr &- footerSize)
        if prevFooter & usedBit == 0 {
            let prevSize = prevFooter
            let prevBlock = blockAddr &- prevSize
            removeFromFreeList(prevBlock)
            blockSize &+= prevSize
            // Move blockAddr to the start of the merged block.
            let mergedAddr = prevBlock
            // Write the merged free block.
            store(mergedAddr, blockSize)
            store(mergedAddr &+ headerSize, freeListHead)
            store(mergedAddr &+ blockSize &- footerSize, blockSize)
            freeListHead = mergedAddr
            return
        }
    }

    // No backward merge — just insert this block at the head of the free list.
    store(blockAddr, blockSize)
    store(blockAddr &+ headerSize, freeListHead)
    store(blockAddr &+ blockSize &- footerSize, blockSize)
    freeListHead = blockAddr
}
