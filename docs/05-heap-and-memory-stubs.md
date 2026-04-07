# Task 5: Heap Allocator & Memory Stubs

## Overview

All C standard library function stubs required for linking Embedded Swift in bare-metal (`-nostdlib`) are implemented **entirely in Swift**.

Files:
- `Sources/HeapAllocator/HeapAllocator.swift` — Free-list allocator (posix_memalign/free)
- `Sources/MemoryPrimitives/MemoryPrimitives.swift` — Memory operations (memset/memcpy/memmove)

## Why Stubs Are Needed

The Embedded Swift compiler references certain C standard function symbols even after optimization.
Since we link with `-nostdlib`, the standard library is not provided, so these must be defined manually.

## Required Stubs

| Function | Purpose | Called By |
|----------|---------|-----------|
| `posix_memalign` | Heap allocation | Swift runtime (`swift_allocObject`, etc.) |
| `free` | Heap deallocation | Swift runtime (object deallocation) |
| `memset` | Memory fill | `swift_once`, etc. |
| `memcpy` | Memory copy (non-overlapping) | Swift runtime |
| `memmove` | Memory copy (overlapping) | `_fatalErrorMessage`, etc. |

## Implementation Details

### Free-List Allocator (posix_memalign / free)

File: `Sources/HeapAllocator/HeapAllocator.swift`

The allocator is isolated in its own `HeapAllocator` SwiftPM target, shared by both the Application and Bootloader executables. This eliminates code duplication and keeps the allocator separate from `MemoryPrimitives` (which requires the special `-disable-loop-idiom-memcpy` LLVM flag that the allocator does not need).

#### Design

A boundary-tagged free-list allocator with first-fit allocation, block splitting, and O(1) coalescing of adjacent free blocks.

**Block layout** (32-bit, UInt = 4 bytes):

```
[size:4] [body: size-8 bytes] [footer:4]
```

| Field | Size | Description |
|-------|------|-------------|
| `size` | 4 bytes | Total block size. Bit 0 = allocated flag (1=used, 0=free) |
| `body` | variable | Free: first 4 bytes = `nextFree` pointer. Allocated: user data |
| `footer` | 4 bytes | Copy of `size` (enables O(1) backward coalescing) |

- Minimum block size: 16 bytes (header + nextFree + pad + footer)
- All block sizes are rounded up to 4-byte alignment (required because bit 0 of the size field is the used/free flag, and headers/footers use 4-byte `UInt` loads/stores)
- Free blocks are linked in an explicit free list via the `nextFree` field

**Alignment handling:**

`posix_memalign` returns pointers aligned to arbitrary power-of-2 values. When the required alignment forces the user pointer away from the block header, a back-pointer is stored at `(userPtr - 4)`. On `free()`, this back-pointer is distinguished from the `size` field by checking bit 0 (size has it set when allocated; a valid block address is always 4-byte aligned, so bit 0 = 0).

**Coalescing:**

On `free()`, both the next and previous adjacent blocks are checked. If free, they are merged into a single larger block using the boundary tags (footer of previous block, header of next block). This prevents fragmentation.

#### Prerequisites

The allocator assumes `.bss` is zeroed before use. Following ESP-IDF's convention, the application's startup code should clear `.bss` before calling any code that uses global variables. The linker script defines `_sbss` / `_ebss` symbols for this purpose.

#### Key Code

```swift
nonisolated(unsafe) var freeListHead: UInt = 0
nonisolated(unsafe) var heapStart: UInt = 0
nonisolated(unsafe) var heapEnd: UInt = 0

@c(posix_memalign)
func posixMemalign(
    _ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: Int,
    _ size: Int
) -> Int32 {
    if heapStart == 0 { initHeap() }
    // First-fit search with block splitting...
}

@c(free)
func freeBlock(_ ptr: UnsafeMutableRawPointer?) {
    // Locate header via back-pointer, coalesce adjacent free blocks...
}
```

- The heap region spans from `_heap_start` (after BSS + stack) to `_heap_end` (`0x40880000`, end of IRAM)
- `_heap_start` / `_heap_end` are linker symbols defined in the linker script
- Allocation returns `ENOMEM` (12) when no free block is large enough
- `free()` supports real deallocation with coalescing, preventing heap exhaustion in long-running applications

### Memory Operation Functions (memset / memcpy / memmove)

File: `Sources/MemoryPrimitives/MemoryPrimitives.swift`

These are isolated in a separate `MemoryPrimitives` SwiftPM target, compiled with `-Xllvm -disable-loop-idiom-memcpy` to prevent LLVM's Loop Idiom Recognition pass from converting the byte-copy loops back into `memcpy`/`memset` calls — which would cause infinite recursion since these *are* the implementations of those functions.

> **Note:** As of Swift 6.3 (`-Osize` / `-O`), LLVM's Loop Idiom Recognition pass does not appear to trigger on these byte-copy loops for the RISC-V target. The `-disable-loop-idiom-memcpy` flag is therefore a **defensive measure** against future compiler versions where this behavior may change.

```swift
@c(memset)
@inline(never)
public func memsetStub(_ dest: UnsafeMutableRawPointer, _ value: Int32, _ count: Int) -> UnsafeMutableRawPointer {
    let byte = UInt8(truncatingIfNeeded: value)
    let ptr = dest.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        ptr[i] = byte
    }
    return dest
}

@c(memcpy)
@inline(never)
public func memcpyStub(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> UnsafeMutableRawPointer {
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let s = src.assumingMemoryBound(to: UInt8.self)
    for i in 0..<count {
        d[i] = s[i]
    }
    return dest
}

@c(memmove)
@inline(never)
public func memmoveStub(_ dest: UnsafeMutableRawPointer, _ src: UnsafeRawPointer, _ count: Int) -> UnsafeMutableRawPointer {
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let s = src.assumingMemoryBound(to: UInt8.self)
    if UInt(bitPattern: d) < UInt(bitPattern: s) {
        for i in 0..<count { d[i] = s[i] }          // Forward copy
    } else if UInt(bitPattern: d) > UInt(bitPattern: s) {
        var i = count
        while i > 0 { i &-= 1; d[i] = s[i] }        // Backward copy
    }
    return dest
}
```

- `@inline(never)` prevents inlining (but alone does not prevent loop idiom recognition)
- `-Xllvm -disable-loop-idiom-memcpy` is the key flag that prevents the LLVM optimization pass from replacing loops with memcpy/memset calls
- By isolating this flag in the `MemoryPrimitives` target, other targets retain full LLVM optimization
- `memmove` determines the copy direction to handle overlapping regions

## Stubs Found to Be Unnecessary

| Stub | Reason Not Needed |
|------|-------------------|
| `__atomic_load_4`, etc. | With `-Osize` on single-core, the compiler optimizes to regular load/store |
| `__stack_chk_guard` / `__stack_chk_fail` | Eliminated with `-Xfrontend -disable-stack-protector` flag |
| `__aeabi_memclr` / `__aeabi_memcpy4`, etc. | ARM EABI-specific symbols; RISC-V uses standard `memset`/`memcpy` |

## Notes

### `free` Symbol Warning

```
warning: symbol name 'free' is reserved for the Swift runtime
```

Swift 6.3 emits a warning for `@c(free)`. It works correctly, but may become an error in future versions.

### Comparison with pico-bare-swift

| Item | pico-bare-swift (ARM) | This Project (RISC-V) |
|------|----------------------|----------------------|
| `__aeabi_memclr` / `__aeabi_memcpy4` | Required (ARM EABI) | Not needed |
| `__atomic_*` | Required (explicitly implemented) | Not needed (`-Osize` optimizes away) |
| `posix_memalign` / `free` | Same | Same |
| `memset` / `memcpy` / `memmove` | Via `__aeabi_*` | Direct |
| `putchar` | None | Not needed (direct USB Serial JTAG output) |
