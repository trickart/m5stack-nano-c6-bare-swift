// IEEE 754 double-precision software floating-point builtins for RV32IMC.
//
// All functions operate on UInt64 bit representations and use only 32-bit
// native operations to avoid hardware FPU dependency.

// MARK: - IEEE 754 Constants

@inline(__always) private var signBit: UInt64       { 0x8000_0000_0000_0000 }
@inline(__always) private var exponentMask: UInt64   { 0x7FF0_0000_0000_0000 }
@inline(__always) private var significandMask: UInt64 { 0x000F_FFFF_FFFF_FFFF }
@inline(__always) private var absMask: UInt64        { 0x7FFF_FFFF_FFFF_FFFF }
@inline(__always) private var implicitBit: UInt64    { 0x0010_0000_0000_0000 }
@inline(__always) private var infRep: UInt64         { 0x7FF0_0000_0000_0000 }
@inline(__always) private var quietNaN: UInt64       { 0x7FF8_0000_0000_0000 }
@inline(__always) private var exponentBias: Int32    { 1023 }
@inline(__always) private var significandBits: Int32  { 52 }

// MARK: - 64-bit Decomposition Helpers (RV32)

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

// MARK: - Helper Functions

@inline(__always)
private func toRep(_ d: Double) -> UInt64 {
    d.bitPattern
}

@inline(__always)
private func fromRep(_ r: UInt64) -> Double {
    Double(bitPattern: r)
}

@inline(__always)
private func extractSign(_ rep: UInt64) -> UInt64 {
    rep & signBit
}

@inline(__always)
private func extractBiasedExponent(_ rep: UInt64) -> Int32 {
    Int32((rep >> 52) & 0x7FF)
}

@inline(__always)
private func extractSignificand(_ rep: UInt64) -> UInt64 {
    rep & significandMask
}

@inline(__always)
private func dfIsNaN(_ rep: UInt64) -> Bool {
    (rep & absMask) > infRep
}

@inline(__always)
private func dfIsInf(_ rep: UInt64) -> Bool {
    (rep & absMask) == infRep
}

@inline(__always)
private func dfIsZero(_ rep: UInt64) -> Bool {
    (rep & absMask) == 0
}

// MARK: - Comparison Helper

/// Returns -1 if a < b, 0 if a == b, 1 if a > b.
/// Precondition: neither operand is NaN.
@inline(__always)
private func cmpdf2(_ aRep: UInt64, _ bRep: UInt64) -> Int32 {
    let aAbs = aRep & absMask
    let bAbs = bRep & absMask

    // ±0 == ±0
    if aAbs == 0 && bAbs == 0 { return 0 }

    let aNeg = (aRep & signBit) != 0
    let bNeg = (bRep & signBit) != 0

    // Different signs
    if aNeg && !bNeg { return -1 }
    if !aNeg && bNeg { return 1 }

    // Same sign — compare magnitudes
    if aNeg {
        // Both negative: larger magnitude = smaller value
        if aAbs > bAbs { return -1 }
        if aAbs < bAbs { return 1 }
        return 0
    } else {
        if aAbs < bAbs { return -1 }
        if aAbs > bAbs { return 1 }
        return 0
    }
}

// MARK: - Wide Multiplication Helper

/// 32×32 → 64 widening multiply (uses RV32IM MUL+MULHU).
@inline(__always)
private func mul32x32(_ a: UInt32, _ b: UInt32) -> UInt64 {
    UInt64(a) &* UInt64(b)
}

/// Returns the high 64 bits of a 128-bit product (a × b).
/// Decomposes into four 32×32 multiplies to avoid needing __muldi3.
@inline(__always)
private func mulhi64(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (aLo, aHi) = split64(a)
    let (bLo, bHi) = split64(b)

    let p0 = mul32x32(aLo, bLo)  // bits 0–63
    let p1 = mul32x32(aHi, bLo)  // bits 32–95
    let p2 = mul32x32(aLo, bHi)  // bits 32–95
    let p3 = mul32x32(aHi, bHi)  // bits 64–127

    // Column 1 (bits 32–63): accumulate carries
    let col1 = UInt64(split64(p0).hi) &+ UInt64(split64(p1).lo) &+ UInt64(split64(p2).lo)
    let col1Carry = split64(col1).hi

    // Columns 2–3 (bits 64–127)
    return p3 &+ UInt64(split64(p1).hi) &+ UInt64(split64(p2).hi) &+ UInt64(col1Carry)
}

/// Returns both halves of a 128-bit product: (low64, high64).
@inline(__always)
private func mul128(_ a: UInt64, _ b: UInt64) -> (lo: UInt64, hi: UInt64) {
    let lo = a &* b
    let hi = mulhi64(a, b)
    return (lo, hi)
}

// MARK: - Conversion: Int → Double

@c(__floatunsidf)
@inline(never)
public func floatunsidf(_ a: UInt32) -> Double {
    if a == 0 { return fromRep(0) }

    let shift = Int32(a.leadingZeroBitCount)
    let exponent = 31 &- shift &+ exponentBias
    let sig = (UInt64(a) << (21 &+ shift)) & significandMask
    let result = (UInt64(exponent) << 52) | sig
    return fromRep(result)
}

@c(__floatsidf)
@inline(never)
public func floatsidf(_ a: Int32) -> Double {
    if a == 0 { return fromRep(0) }

    let sign: UInt64 = a < 0 ? signBit : 0
    let mag: UInt32 = a < 0 ? 0 &- UInt32(bitPattern: a) : UInt32(bitPattern: a)

    let shift = Int32(mag.leadingZeroBitCount)
    let exponent = 31 &- shift &+ exponentBias
    let sig = (UInt64(mag) << (21 &+ shift)) & significandMask
    let result = sign | (UInt64(exponent) << 52) | sig
    return fromRep(result)
}

@c(__floatdidf)
@inline(never)
public func floatdidf(_ a: Int64) -> Double {
    if a == 0 { return fromRep(0) }

    let sign: UInt64 = a < 0 ? signBit : 0
    let mag: UInt64 = a < 0 ? 0 &- UInt64(bitPattern: a) : UInt64(bitPattern: a)

    let clz = Int32(mag.leadingZeroBitCount)
    let msbPos = 63 &- clz

    var exponent = msbPos &+ exponentBias

    var sig: UInt64
    if msbPos <= significandBits {
        sig = (mag << (significandBits &- msbPos)) & significandMask
    } else {
        let shiftAmount = msbPos &- significandBits
        let roundBit = (mag >> (shiftAmount &- 1)) & 1
        let stickyMask = (UInt64(1) << (shiftAmount &- 1)) &- 1
        let sticky: UInt64 = (mag & stickyMask) != 0 ? 1 : 0

        sig = (mag >> shiftAmount) & significandMask

        if roundBit != 0 && (sticky != 0 || (sig & 1) != 0) {
            sig &+= 1
            if sig > significandMask {
                sig = 0
                exponent &+= 1
            }
        }
    }

    return fromRep(sign | (UInt64(exponent) << 52) | sig)
}

@c(__floatundidf)
@inline(never)
public func floatundidf(_ a: UInt64) -> Double {
    if a == 0 { return fromRep(0) }

    let clz = Int32(a.leadingZeroBitCount)
    let msbPos = 63 &- clz

    var exponent = msbPos &+ exponentBias

    var sig: UInt64
    if msbPos <= significandBits {
        sig = (a << (significandBits &- msbPos)) & significandMask
    } else {
        let shiftAmount = msbPos &- significandBits
        let roundBit = (a >> (shiftAmount &- 1)) & 1
        let stickyMask = (UInt64(1) << (shiftAmount &- 1)) &- 1
        let sticky: UInt64 = (a & stickyMask) != 0 ? 1 : 0

        sig = (a >> shiftAmount) & significandMask

        if roundBit != 0 && (sticky != 0 || (sig & 1) != 0) {
            sig &+= 1
            if sig > significandMask {
                sig = 0
                exponent &+= 1
            }
        }
    }

    return fromRep((UInt64(exponent) << 52) | sig)
}

// MARK: - Conversion: Double → Int

@c(__fixdfsi)
@inline(never)
public func fixdfsi(_ a: Double) -> Int32 {
    let rep = toRep(a)
    let sign = extractSign(rep)
    let biasedExp = extractBiasedExponent(rep)
    let sig = extractSignificand(rep)
    let e = biasedExp &- exponentBias

    if dfIsNaN(rep) { return 0 }
    if biasedExp < exponentBias { return 0 }
    if e >= 31 { return sign != 0 ? Int32.min : Int32.max }

    let withImplicit = sig | implicitBit
    let result: Int32
    if e >= significandBits {
        result = Int32(truncatingIfNeeded: withImplicit << (e &- significandBits))
    } else {
        result = Int32(truncatingIfNeeded: withImplicit >> (significandBits &- e))
    }

    return sign != 0 ? (0 &- result) : result
}

@c(__fixunsdfsi)
@inline(never)
public func fixunsdfsi(_ a: Double) -> UInt32 {
    let rep = toRep(a)
    let biasedExp = extractBiasedExponent(rep)
    let sig = extractSignificand(rep)

    if (rep & signBit) != 0 { return 0 }
    if dfIsNaN(rep) { return 0 }
    if biasedExp < exponentBias { return 0 }

    let e = biasedExp &- exponentBias
    if e >= 32 { return UInt32.max }

    let withImplicit = sig | implicitBit
    if e >= significandBits {
        return UInt32(truncatingIfNeeded: withImplicit << (e &- significandBits))
    } else {
        return UInt32(truncatingIfNeeded: withImplicit >> (significandBits &- e))
    }
}

@c(__fixdfdi)
@inline(never)
public func fixdfdi(_ a: Double) -> Int64 {
    let rep = toRep(a)
    let sign = extractSign(rep)
    let biasedExp = extractBiasedExponent(rep)
    let sig = extractSignificand(rep)
    let e = biasedExp &- exponentBias

    if dfIsNaN(rep) { return 0 }
    if biasedExp < exponentBias { return 0 }
    if e >= 63 { return sign != 0 ? Int64.min : Int64.max }

    let withImplicit = sig | implicitBit
    let result: Int64
    if e >= significandBits {
        result = Int64(withImplicit << (e &- significandBits))
    } else {
        result = Int64(withImplicit >> (significandBits &- e))
    }

    return sign != 0 ? (0 &- result) : result
}

@c(__fixunsdfdi)
@inline(never)
public func fixunsdfdi(_ a: Double) -> UInt64 {
    let rep = toRep(a)
    let biasedExp = extractBiasedExponent(rep)
    let sig = extractSignificand(rep)

    if (rep & signBit) != 0 { return 0 }
    if dfIsNaN(rep) { return 0 }
    if biasedExp < exponentBias { return 0 }

    let e = biasedExp &- exponentBias
    if e >= 64 { return UInt64.max }

    let withImplicit = sig | implicitBit
    if e >= significandBits {
        return withImplicit << (e &- significandBits)
    } else {
        return withImplicit >> (significandBits &- e)
    }
}

// MARK: - Comparisons

@c(__unorddf2)
@inline(never)
public func unorddf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return 1 }
    return 0
}

@c(__eqdf2)
@inline(never)
public func eqdf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return 1 }
    return cmpdf2(aRep, bRep) != 0 ? 1 : 0
}

@c(__nedf2)
@inline(never)
public func nedf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return 1 }
    return cmpdf2(aRep, bRep) != 0 ? 1 : 0
}

@c(__ltdf2)
@inline(never)
public func ltdf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return 1 }
    return cmpdf2(aRep, bRep)
}

@c(__ledf2)
@inline(never)
public func ledf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return 1 }
    return cmpdf2(aRep, bRep)
}

@c(__gtdf2)
@inline(never)
public func gtdf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return -1 }
    return cmpdf2(aRep, bRep)
}

@c(__gedf2)
@inline(never)
public func gedf2(_ a: Double, _ b: Double) -> Int32 {
    let aRep = toRep(a)
    let bRep = toRep(b)
    if dfIsNaN(aRep) || dfIsNaN(bRep) { return -1 }
    return cmpdf2(aRep, bRep)
}

// MARK: - __adddf3 — Double Addition

@c(__adddf3)
@inline(never)
public func adddf3(_ a: Double, _ b: Double) -> Double {
    var aRep = toRep(a)
    var bRep = toRep(b)

    if dfIsNaN(aRep) { return fromRep(aRep | quietNaN) }
    if dfIsNaN(bRep) { return fromRep(bRep | quietNaN) }

    let aInf = dfIsInf(aRep)
    let bInf = dfIsInf(bRep)
    if aInf && bInf {
        if (aRep ^ bRep) & signBit != 0 { return fromRep(quietNaN) }
        return a
    }
    if aInf { return a }
    if bInf { return b }

    if dfIsZero(aRep) {
        if dfIsZero(bRep) { return fromRep(aRep & bRep & signBit) }
        return b
    }
    if dfIsZero(bRep) { return a }

    if (aRep & absMask) < (bRep & absMask) {
        let tmp = aRep; aRep = bRep; bRep = tmp
    }

    let aSign = aRep & signBit
    let bSign = bRep & signBit
    var aExp = extractBiasedExponent(aRep)
    var bExp = extractBiasedExponent(bRep)
    var aSig = extractSignificand(aRep)
    var bSig = extractSignificand(bRep)

    if aExp != 0 { aSig |= implicitBit } else { aExp = 1 }
    if bExp != 0 { bSig |= implicitBit } else { bExp = 1 }

    let expDiff = aExp &- bExp

    let aSig3 = aSig << 3
    var bSig3 = bSig << 3

    if expDiff > 0 {
        if expDiff < 64 {
            let stickyMask = (UInt64(1) << expDiff) &- 1
            let sticky: UInt64 = (bSig3 & stickyMask) != 0 ? 1 : 0
            bSig3 = (bSig3 >> expDiff) | sticky
        } else {
            bSig3 = 1
        }
    }

    var resultExp = aExp
    var resultSig: UInt64
    let resultSign: UInt64

    if aSign == bSign {
        resultSign = aSign
        resultSig = aSig3 &+ bSig3
        if resultSig & (implicitBit << 4) != 0 {
            let sticky: UInt64 = (resultSig & 1) != 0 ? 1 : 0
            resultSig = (resultSig >> 1) | sticky
            resultExp &+= 1
        }
    } else {
        resultSign = aSign
        resultSig = aSig3 &- bSig3
        if resultSig == 0 { return fromRep(0) }
        let targetBit: UInt64 = implicitBit << 3
        while resultSig & targetBit == 0 && resultExp > 1 {
            resultSig <<= 1
            resultExp &-= 1
        }
    }

    let roundBits = resultSig & 0x7
    resultSig >>= 3
    resultSig &= significandMask

    if roundBits > 4 || (roundBits == 4 && (resultSig & 1) != 0) {
        resultSig &+= 1
        if resultSig > significandMask {
            resultSig = 0
            resultExp &+= 1
        }
    }

    if resultExp >= 0x7FF { return fromRep(resultSign | infRep) }
    if resultExp <= 0 { return fromRep(resultSign) }

    return fromRep(resultSign | (UInt64(resultExp) << 52) | resultSig)
}

// MARK: - __subdf3 — Double Subtraction

@c(__subdf3)
@inline(never)
public func subdf3(_ a: Double, _ b: Double) -> Double {
    return adddf3(a, fromRep(toRep(b) ^ signBit))
}

// MARK: - __muldf3 — Double Multiplication

@c(__muldf3)
@inline(never)
public func muldf3(_ a: Double, _ b: Double) -> Double {
    let aRep = toRep(a)
    let bRep = toRep(b)

    let resultSign = (aRep ^ bRep) & signBit

    if dfIsNaN(aRep) { return fromRep(aRep | quietNaN) }
    if dfIsNaN(bRep) { return fromRep(bRep | quietNaN) }

    if dfIsInf(aRep) && dfIsZero(bRep) { return fromRep(quietNaN) }
    if dfIsZero(aRep) && dfIsInf(bRep) { return fromRep(quietNaN) }

    if dfIsInf(aRep) || dfIsInf(bRep) { return fromRep(resultSign | infRep) }
    if dfIsZero(aRep) || dfIsZero(bRep) { return fromRep(resultSign) }

    var aExp = extractBiasedExponent(aRep)
    var bExp = extractBiasedExponent(bRep)
    var aSig = extractSignificand(aRep)
    var bSig = extractSignificand(bRep)

    if aExp == 0 {
        let shift = Int32((aSig | implicitBit).leadingZeroBitCount) &- 11
        aSig = (aSig << shift) & significandMask
        aExp = 1 &- shift
    }
    if bExp == 0 {
        let shift = Int32((bSig | implicitBit).leadingZeroBitCount) &- 11
        bSig = (bSig << shift) & significandMask
        bExp = 1 &- shift
    }

    aSig |= implicitBit
    bSig |= implicitBit

    let wideA = aSig << 11
    let wideB = bSig << 11
    let (productLo, productHi) = mul128(wideA, wideB)

    var resultExp = aExp &+ bExp &- exponentBias

    var resultSig: UInt64
    if productHi & signBit != 0 {
        resultSig = productHi >> 11
        resultExp &+= 1
    } else {
        resultSig = productHi >> 10
    }

    let roundBit: UInt64
    let stickyBit: Bool
    if productHi & signBit != 0 {
        roundBit = productHi & (1 << 10)
        stickyBit = (productHi & ((1 << 10) &- 1)) != 0 || productLo != 0
    } else {
        roundBit = productHi & (1 << 9)
        stickyBit = (productHi & ((1 << 9) &- 1)) != 0 || productLo != 0
    }

    resultSig &= significandMask

    if roundBit != 0 {
        if stickyBit || (resultSig & 1) != 0 {
            resultSig &+= 1
            if resultSig > significandMask {
                resultSig = 0
                resultExp &+= 1
            }
        }
    }

    if resultExp >= 0x7FF { return fromRep(resultSign | infRep) }
    if resultExp <= 0 { return fromRep(resultSign) }

    return fromRep(resultSign | (UInt64(resultExp) << 52) | resultSig)
}

// MARK: - __divdf3 — Double Division

@c(__divdf3)
@inline(never)
public func divdf3(_ a: Double, _ b: Double) -> Double {
    let aRep = toRep(a)
    let bRep = toRep(b)

    let resultSign = (aRep ^ bRep) & signBit

    if dfIsNaN(aRep) { return fromRep(aRep | quietNaN) }
    if dfIsNaN(bRep) { return fromRep(bRep | quietNaN) }

    if dfIsInf(aRep) && dfIsInf(bRep) { return fromRep(quietNaN) }
    if dfIsZero(aRep) && dfIsZero(bRep) { return fromRep(quietNaN) }

    if dfIsInf(aRep) { return fromRep(resultSign | infRep) }
    if dfIsInf(bRep) { return fromRep(resultSign) }
    if dfIsZero(bRep) { return fromRep(resultSign | infRep) }
    if dfIsZero(aRep) { return fromRep(resultSign) }

    var aExp = extractBiasedExponent(aRep)
    var bExp = extractBiasedExponent(bRep)
    var aSig = extractSignificand(aRep)
    var bSig = extractSignificand(bRep)

    if aExp == 0 {
        let shift = Int32((aSig | implicitBit).leadingZeroBitCount) &- 11
        aSig = (aSig << shift) & significandMask
        aExp = 1 &- shift
    }
    if bExp == 0 {
        let shift = Int32((bSig | implicitBit).leadingZeroBitCount) &- 11
        bSig = (bSig << shift) & significandMask
        bExp = 1 &- shift
    }

    aSig |= implicitBit
    bSig |= implicitBit

    var resultExp = aExp &- bExp &+ exponentBias

    var remainder = aSig
    var quotient: UInt64 = 0

    if remainder >= bSig {
        remainder &-= bSig
        quotient = 1
    } else {
        resultExp &-= 1
    }

    var i: Int32 = 0
    while i < 53 {
        remainder <<= 1
        quotient <<= 1
        if remainder >= bSig {
            remainder &-= bSig
            quotient |= 1
        }
        i &+= 1
    }

    if remainder != 0 {
        quotient |= 1
    }

    let roundBit = quotient & 1
    quotient >>= 1

    let resultSig = quotient & significandMask

    if roundBit != 0 {
        if (remainder != 0) || (resultSig & 1) != 0 {
            let rounded = resultSig &+ 1
            if rounded > significandMask {
                resultExp &+= 1
                if resultExp >= 0x7FF {
                    return fromRep(resultSign | infRep)
                }
                return fromRep(resultSign | (UInt64(resultExp) << 52))
            }
            return fromRep(resultSign | (UInt64(resultExp) << 52) | rounded)
        }
    }

    if resultExp >= 0x7FF { return fromRep(resultSign | infRep) }
    if resultExp <= 0 { return fromRep(resultSign) }

    return fromRep(resultSign | (UInt64(resultExp) << 52) | resultSig)
}

// MARK: - ceil — Ceiling Function

@c(ceil)
@inline(never)
public func ceilImpl(_ x: Double) -> Double {
    let rep = toRep(x)
    let biasedExp = extractBiasedExponent(rep)

    if biasedExp >= exponentBias &+ significandBits { return x }

    if biasedExp < exponentBias {
        if dfIsZero(rep) { return x }
        if (rep & signBit) != 0 { return fromRep(signBit) }
        return fromRep(0x3FF0_0000_0000_0000)  // 1.0
    }

    let e = biasedExp &- exponentBias
    let fracMask = significandMask >> e

    if (rep & fracMask) == 0 { return x }

    if (rep & signBit) == 0 {
        return fromRep((rep | fracMask) &+ 1)
    } else {
        return fromRep(rep & ~fracMask)
    }
}

// MARK: - floor — Floor Function

@c(floor)
@inline(never)
public func floorImpl(_ x: Double) -> Double {
    let rep = toRep(x)
    let biasedExp = extractBiasedExponent(rep)

    if biasedExp >= exponentBias &+ significandBits { return x }

    if biasedExp < exponentBias {
        if dfIsZero(rep) { return x }
        if (rep & signBit) != 0 {
            return fromRep(0xBFF0_0000_0000_0000)  // -1.0
        }
        return fromRep(0)
    }

    let e = biasedExp &- exponentBias
    let fracMask = significandMask >> e

    if (rep & fracMask) == 0 { return x }

    if (rep & signBit) != 0 {
        return fromRep((rep | fracMask) &+ 1)
    } else {
        return fromRep(rep & ~fracMask)
    }
}
