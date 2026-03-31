// Memory operation stubs required by Embedded Swift on bare-metal RISC-V.
//
// These replace the C standard library's memset/memcpy/memmove since
// we link with -nostdlib.
//
// This target is compiled with -Xllvm -disable-loop-idiom-memcpy to
// prevent LLVM from recognizing byte-copy loops and replacing them
// with calls to the very functions defined here (infinite recursion).

@c(memset)
@inline(never)
public func memsetStub(
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
public func memcpyStub(
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
public func memmoveStub(
    _ dest: UnsafeMutableRawPointer,
    _ src: UnsafeRawPointer,
    _ count: Int
) -> UnsafeMutableRawPointer {
    let d = dest.assumingMemoryBound(to: UInt8.self)
    let s = src.assumingMemoryBound(to: UInt8.self)
    if UInt(bitPattern: d) < UInt(bitPattern: s) {
        // Copy forward
        for i in 0..<count {
            d[i] = s[i]
        }
    } else if UInt(bitPattern: d) > UInt(bitPattern: s) {
        // Copy backward
        var i = count
        while i > 0 {
            i &-= 1
            d[i] = s[i]
        }
    }
    return dest
}
