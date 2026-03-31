# Task 5: Runtime Stub Implementation (in Swift)

## Overview

All C standard library function stubs required for linking Embedded Swift in bare-metal (`-nostdlib`) are implemented **entirely in Swift**.

Files:
- `Sources/MemoryPrimitives/MemoryPrimitives.swift` — Memory operations (memset/memcpy/memmove)
- `Sources/Application/Support/RuntimeStubs.swift` — Heap allocator (posix_memalign/free)
- `Sources/Bootloader/RuntimeStubs.swift` — Heap allocator (bootloader copy)

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

### Bump Allocator (posix_memalign / free)

```swift
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
func freeStub(_ ptr: UnsafeMutableRawPointer?) {
    // No-op: bump allocator never frees.
}
```

- The heap grows upward from `_heap_start` (end of BSS)
- `_heap_end` (end of IRAM `0x40880000`) is the upper limit (defined in the linker script)
- Allocation checks against `_heap_end` and returns `ENOMEM` (12) on overflow
- `free` is a no-op (a sufficient strategy for embedded)

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
