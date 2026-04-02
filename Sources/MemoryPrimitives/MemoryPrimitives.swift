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

// 64-bit shift helpers required by compiler-rt on RV32.
// Must use only 32-bit operations and pointer tricks to avoid
// any 64-bit shift that would recursively call back into these.

/// Split a UInt64 into (lo, hi) UInt32 halves without 64-bit shifts.
@inline(__always)
private func split64(_ value: UInt64) -> (lo: UInt32, hi: UInt32) {
    var v = value
    return withUnsafePointer(to: &v) { ptr in
        let p = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        return (p[0], p[1])  // little-endian RISC-V
    }
}

/// Construct a UInt64 from (lo, hi) UInt32 halves without 64-bit shifts.
@inline(__always)
private func make64(lo: UInt32, hi: UInt32) -> UInt64 {
    var result: UInt64 = 0
    withUnsafeMutablePointer(to: &result) { ptr in
        let p = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        p[0] = lo  // little-endian RISC-V
        p[1] = hi
    }
    return result
}

@c(__ashldi3)
@inline(never)
public func ashldi3(_ a: UInt64, _ b: Int32) -> UInt64 {
    let (lo, hi) = split64(a)
    if b >= 32 {
        return make64(lo: 0, hi: lo << (b &- 32))
    } else if b == 0 {
        return a
    } else {
        return make64(lo: lo << b, hi: (hi << b) | (lo >> (32 &- b)))
    }
}

@c(__lshrdi3)
@inline(never)
public func lshrdi3(_ a: UInt64, _ b: Int32) -> UInt64 {
    let (lo, hi) = split64(a)
    if b >= 32 {
        return make64(lo: hi >> (b &- 32), hi: 0)
    } else if b == 0 {
        return a
    } else {
        return make64(lo: (lo >> b) | (hi << (32 &- b)), hi: hi >> b)
    }
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
