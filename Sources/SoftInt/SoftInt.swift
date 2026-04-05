// 64-bit integer arithmetic helpers required by compiler-rt on RV32.
//
// On 32-bit RISC-V, the compiler emits calls to these functions for
// 64-bit multiply, divide, and modulo operations. Since we link with
// -nostdlib, we must provide them ourselves.

// MARK: - 64-bit ↔ 32-bit helpers

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

/// Multiply two UInt32 values and return the full 64-bit result.
@inline(__always)
private func mul32x32(_ a: UInt32, _ b: UInt32) -> UInt64 {
    // Use multipliedFullWidth to get 64-bit result from 32-bit operands
    // without triggering __muldi3.
    let (high, low) = a.multipliedFullWidth(by: b)
    return make64(lo: low, hi: high)
}

// MARK: - 64-bit multiplication

@c(__muldi3)
@inline(never)
public func muldi3(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (aLo, aHi) = split64(a)
    let (bLo, bHi) = split64(b)

    // a * b = (aHi * 2^32 + aLo) * (bHi * 2^32 + bLo)
    //       = aLo*bLo + (aLo*bHi + aHi*bLo) * 2^32
    //       (aHi*bHi * 2^64 overflows and is discarded)
    let lo_lo = mul32x32(aLo, bLo)
    let (llLo, llHi) = split64(lo_lo)

    // Cross terms — only the low 32 bits of each contribute to the result
    let cross: UInt32 = llHi &+ (aLo &* bHi) &+ (aHi &* bLo)

    return make64(lo: llLo, hi: cross)
}

// MARK: - 64-bit unsigned division and modulo

/// Unsigned 64-bit division via binary long division using only 32-bit ops.
/// Returns (quotient, remainder).
private func udivmod64(_ dividend: UInt64, _ divisor: UInt64) -> (UInt64, UInt64) {
    // Handle division by zero — return 0 (no trap on bare metal)
    let (dLo, dHi) = split64(divisor)
    if dLo == 0 && dHi == 0 {
        return (0, 0)
    }

    // Fast path: if both fit in 32 bits, use hardware division
    let (nLo, nHi) = split64(dividend)
    if nHi == 0 && dHi == 0 {
        return (make64(lo: nLo / dLo, hi: 0),
                make64(lo: nLo % dLo, hi: 0))
    }

    // Binary long division
    var quotient: UInt64 = 0
    var remainder: UInt64 = 0

    var i: Int32 = 63
    while i >= 0 {
        // remainder = (remainder << 1) | bit i of dividend
        let (rLo, rHi) = split64(remainder)
        let newRLo = (rLo << 1)
        let newRHi = (rHi << 1) | (rLo >> 31)

        // Extract bit i from dividend
        let (qLo, qHi) = split64(dividend)
        let bit: UInt32
        if i >= 32 {
            bit = (qHi >> (i &- 32)) & 1
        } else {
            bit = (qLo >> i) & 1
        }
        remainder = make64(lo: newRLo | bit, hi: newRHi)

        // if remainder >= divisor
        let (remLo, remHi) = split64(remainder)
        let geq: Bool
        if remHi > dHi {
            geq = true
        } else if remHi == dHi {
            geq = remLo >= dLo
        } else {
            geq = false
        }

        if geq {
            // remainder -= divisor (manual 64-bit subtraction)
            let subLo = remLo &- dLo
            var subHi = remHi &- dHi
            if remLo < dLo {
                subHi = subHi &- 1  // borrow
            }
            remainder = make64(lo: subLo, hi: subHi)

            // quotient |= (1 << i)
            let (curQLo, curQHi) = split64(quotient)
            if i >= 32 {
                quotient = make64(lo: curQLo, hi: curQHi | (1 << (i &- 32)))
            } else {
                quotient = make64(lo: curQLo | (1 << i), hi: curQHi)
            }
        }

        i &-= 1
    }

    return (quotient, remainder)
}

@c(__udivdi3)
@inline(never)
public func udivdi3(_ a: UInt64, _ b: UInt64) -> UInt64 {
    return udivmod64(a, b).0
}

@c(__umoddi3)
@inline(never)
public func umoddi3(_ a: UInt64, _ b: UInt64) -> UInt64 {
    return udivmod64(a, b).1
}

// MARK: - 64-bit signed division and modulo

@c(__divdi3)
@inline(never)
public func divdi3(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (_, aHi) = split64(a)
    let (_, bHi) = split64(b)
    let aNeg = (aHi & 0x8000_0000) != 0
    let bNeg = (bHi & 0x8000_0000) != 0

    // Negate: ~x + 1
    let absA: UInt64 = aNeg ? negate64(a) : a
    let absB: UInt64 = bNeg ? negate64(b) : b

    let q = udivmod64(absA, absB).0
    return (aNeg != bNeg) ? negate64(q) : q
}

@c(__moddi3)
@inline(never)
public func moddi3(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (_, aHi) = split64(a)
    let (_, bHi) = split64(b)
    let aNeg = (aHi & 0x8000_0000) != 0
    let bNeg = (bHi & 0x8000_0000) != 0

    let absA: UInt64 = aNeg ? negate64(a) : a
    let absB: UInt64 = bNeg ? negate64(b) : b

    let r = udivmod64(absA, absB).1
    // Remainder sign follows dividend sign
    return aNeg ? negate64(r) : r
}

/// Two's complement negation of a 64-bit value using 32-bit ops.
@inline(__always)
private func negate64(_ x: UInt64) -> UInt64 {
    let (lo, hi) = split64(x)
    let newLo = ~lo &+ 1
    var newHi = ~hi
    if newLo == 0 { newHi = newHi &+ 1 }  // carry
    return make64(lo: newLo, hi: newHi)
}
