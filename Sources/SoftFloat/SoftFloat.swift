// IEEE 754 single-precision software floating-point builtins for RV32IMC.
//
// All functions operate on UInt32 bit representations. Single-precision
// arithmetic fits entirely in 32-bit registers, with multiplication
// using UInt64 for the 48-bit intermediate product.

// MARK: - IEEE 754 Single-Precision Constants

@inline(__always) private var sfSignBit: UInt32       { 0x8000_0000 }
@inline(__always) private var sfExponentMask: UInt32   { 0x7F80_0000 }
@inline(__always) private var sfSignificandMask: UInt32 { 0x007F_FFFF }
@inline(__always) private var sfAbsMask: UInt32        { 0x7FFF_FFFF }
@inline(__always) private var sfImplicitBit: UInt32    { 0x0080_0000 }
@inline(__always) private var sfInfRep: UInt32         { 0x7F80_0000 }
@inline(__always) private var sfQuietNaN: UInt32       { 0x7FC0_0000 }
@inline(__always) private var sfExponentBias: Int32    { 127 }
@inline(__always) private var sfSignificandBits: Int32  { 23 }

// MARK: - Helper Functions

@inline(__always)
private func sfToRep(_ f: Float) -> UInt32 {
    f.bitPattern
}

@inline(__always)
private func sfFromRep(_ r: UInt32) -> Float {
    Float(bitPattern: r)
}

@inline(__always)
private func sfExtractSign(_ rep: UInt32) -> UInt32 {
    rep & sfSignBit
}

@inline(__always)
private func sfExtractBiasedExponent(_ rep: UInt32) -> Int32 {
    Int32((rep >> 23) & 0xFF)
}

@inline(__always)
private func sfExtractSignificand(_ rep: UInt32) -> UInt32 {
    rep & sfSignificandMask
}

@inline(__always)
private func sfIsNaN(_ rep: UInt32) -> Bool {
    (rep & sfAbsMask) > sfInfRep
}

@inline(__always)
private func sfIsInf(_ rep: UInt32) -> Bool {
    (rep & sfAbsMask) == sfInfRep
}

@inline(__always)
private func sfIsZero(_ rep: UInt32) -> Bool {
    (rep & sfAbsMask) == 0
}

// MARK: - Comparison Helper

@inline(__always)
private func cmpsf2(_ aRep: UInt32, _ bRep: UInt32) -> Int32 {
    let aAbs = aRep & sfAbsMask
    let bAbs = bRep & sfAbsMask

    if aAbs == 0 && bAbs == 0 { return 0 }

    let aNeg = (aRep & sfSignBit) != 0
    let bNeg = (bRep & sfSignBit) != 0

    if aNeg && !bNeg { return -1 }
    if !aNeg && bNeg { return 1 }

    if aNeg {
        if aAbs > bAbs { return -1 }
        if aAbs < bAbs { return 1 }
        return 0
    } else {
        if aAbs < bAbs { return -1 }
        if aAbs > bAbs { return 1 }
        return 0
    }
}

// MARK: - Conversion: Int → Float

@c(__floatunsisf)
@inline(never)
public func floatunsisf(_ a: UInt32) -> Float {
    if a == 0 { return sfFromRep(0) }

    let clz = Int32(a.leadingZeroBitCount)
    let msbPos = 31 &- clz

    var exponent = msbPos &+ sfExponentBias

    var sig: UInt32
    if msbPos <= sfSignificandBits {
        sig = (a << (sfSignificandBits &- msbPos)) & sfSignificandMask
    } else {
        let shiftAmount = msbPos &- sfSignificandBits
        let roundBit = (a >> (shiftAmount &- 1)) & 1
        let stickyMask = (UInt32(1) << (shiftAmount &- 1)) &- 1
        let sticky: UInt32 = (a & stickyMask) != 0 ? 1 : 0

        sig = (a >> shiftAmount) & sfSignificandMask

        if roundBit != 0 && (sticky != 0 || (sig & 1) != 0) {
            sig &+= 1
            if sig > sfSignificandMask {
                sig = 0
                exponent &+= 1
            }
        }
    }

    return sfFromRep(UInt32(exponent) << 23 | sig)
}

@c(__floatsisf)
@inline(never)
public func floatsisf(_ a: Int32) -> Float {
    if a == 0 { return sfFromRep(0) }

    let sign: UInt32 = a < 0 ? sfSignBit : 0
    let mag: UInt32 = a < 0 ? 0 &- UInt32(bitPattern: a) : UInt32(bitPattern: a)

    let clz = Int32(mag.leadingZeroBitCount)
    let msbPos = 31 &- clz

    var exponent = msbPos &+ sfExponentBias

    var sig: UInt32
    if msbPos <= sfSignificandBits {
        sig = (mag << (sfSignificandBits &- msbPos)) & sfSignificandMask
    } else {
        let shiftAmount = msbPos &- sfSignificandBits
        let roundBit = (mag >> (shiftAmount &- 1)) & 1
        let stickyMask = (UInt32(1) << (shiftAmount &- 1)) &- 1
        let sticky: UInt32 = (mag & stickyMask) != 0 ? 1 : 0

        sig = (mag >> shiftAmount) & sfSignificandMask

        if roundBit != 0 && (sticky != 0 || (sig & 1) != 0) {
            sig &+= 1
            if sig > sfSignificandMask {
                sig = 0
                exponent &+= 1
            }
        }
    }

    return sfFromRep(sign | UInt32(exponent) << 23 | sig)
}

@c(__floatdisf)
@inline(never)
public func floatdisf(_ a: Int64) -> Float {
    if a == 0 { return sfFromRep(0) }

    let sign: UInt32 = a < 0 ? sfSignBit : 0
    let mag: UInt64 = a < 0 ? 0 &- UInt64(bitPattern: a) : UInt64(bitPattern: a)

    let clz = Int32(mag.leadingZeroBitCount)
    let msbPos = 63 &- clz

    var exponent = msbPos &+ sfExponentBias

    var sig: UInt32
    if msbPos <= sfSignificandBits {
        sig = UInt32(truncatingIfNeeded: mag << (sfSignificandBits &- msbPos)) & sfSignificandMask
    } else {
        let shiftAmount = msbPos &- sfSignificandBits
        let roundBit = UInt32(truncatingIfNeeded: (mag >> (shiftAmount &- 1)) & 1)
        let stickyMask = (UInt64(1) << (shiftAmount &- 1)) &- 1
        let sticky: UInt32 = (mag & stickyMask) != 0 ? 1 : 0

        sig = UInt32(truncatingIfNeeded: mag >> shiftAmount) & sfSignificandMask

        if roundBit != 0 && (sticky != 0 || (sig & 1) != 0) {
            sig &+= 1
            if sig > sfSignificandMask {
                sig = 0
                exponent &+= 1
            }
        }
    }

    return sfFromRep(sign | UInt32(exponent) << 23 | sig)
}

@c(__floatundisf)
@inline(never)
public func floatundisf(_ a: UInt64) -> Float {
    if a == 0 { return sfFromRep(0) }

    let clz = Int32(a.leadingZeroBitCount)
    let msbPos = 63 &- clz

    var exponent = msbPos &+ sfExponentBias

    var sig: UInt32
    if msbPos <= sfSignificandBits {
        sig = UInt32(truncatingIfNeeded: a << (sfSignificandBits &- msbPos)) & sfSignificandMask
    } else {
        let shiftAmount = msbPos &- sfSignificandBits
        let roundBit = UInt32(truncatingIfNeeded: (a >> (shiftAmount &- 1)) & 1)
        let stickyMask = (UInt64(1) << (shiftAmount &- 1)) &- 1
        let sticky: UInt32 = (a & stickyMask) != 0 ? 1 : 0

        sig = UInt32(truncatingIfNeeded: a >> shiftAmount) & sfSignificandMask

        if roundBit != 0 && (sticky != 0 || (sig & 1) != 0) {
            sig &+= 1
            if sig > sfSignificandMask {
                sig = 0
                exponent &+= 1
            }
        }
    }

    return sfFromRep(UInt32(exponent) << 23 | sig)
}

// MARK: - Conversion: Float → Int

@c(__fixsfsi)
@inline(never)
public func fixsfsi(_ a: Float) -> Int32 {
    let rep = sfToRep(a)
    let sign = sfExtractSign(rep)
    let biasedExp = sfExtractBiasedExponent(rep)
    let sig = sfExtractSignificand(rep)
    let e = biasedExp &- sfExponentBias

    if sfIsNaN(rep) { return 0 }
    if biasedExp < sfExponentBias { return 0 }
    if e >= 31 { return sign != 0 ? Int32.min : Int32.max }

    let withImplicit = sig | sfImplicitBit
    let result: Int32
    if e >= sfSignificandBits {
        result = Int32(bitPattern: withImplicit << (e &- sfSignificandBits))
    } else {
        result = Int32(bitPattern: withImplicit >> (sfSignificandBits &- e))
    }

    return sign != 0 ? (0 &- result) : result
}

@c(__fixunssfsi)
@inline(never)
public func fixunssfsi(_ a: Float) -> UInt32 {
    let rep = sfToRep(a)
    let biasedExp = sfExtractBiasedExponent(rep)
    let sig = sfExtractSignificand(rep)

    if (rep & sfSignBit) != 0 { return 0 }
    if sfIsNaN(rep) { return 0 }
    if biasedExp < sfExponentBias { return 0 }

    let e = biasedExp &- sfExponentBias
    if e >= 32 { return UInt32.max }

    let withImplicit = sig | sfImplicitBit
    if e >= sfSignificandBits {
        return withImplicit << (e &- sfSignificandBits)
    } else {
        return withImplicit >> (sfSignificandBits &- e)
    }
}

@c(__fixsfdi)
@inline(never)
public func fixsfdi(_ a: Float) -> Int64 {
    let rep = sfToRep(a)
    let sign = sfExtractSign(rep)
    let biasedExp = sfExtractBiasedExponent(rep)
    let sig = sfExtractSignificand(rep)
    let e = biasedExp &- sfExponentBias

    if sfIsNaN(rep) { return 0 }
    if biasedExp < sfExponentBias { return 0 }
    if e >= 63 { return sign != 0 ? Int64.min : Int64.max }

    let withImplicit = UInt64(sig | sfImplicitBit)
    let result: Int64
    if e >= sfSignificandBits {
        result = Int64(withImplicit << (e &- sfSignificandBits))
    } else {
        result = Int64(withImplicit >> (sfSignificandBits &- e))
    }

    return sign != 0 ? (0 &- result) : result
}

@c(__fixunssfdi)
@inline(never)
public func fixunssfdi(_ a: Float) -> UInt64 {
    let rep = sfToRep(a)
    let biasedExp = sfExtractBiasedExponent(rep)
    let sig = sfExtractSignificand(rep)

    if (rep & sfSignBit) != 0 { return 0 }
    if sfIsNaN(rep) { return 0 }
    if biasedExp < sfExponentBias { return 0 }

    let e = biasedExp &- sfExponentBias
    if e >= 64 { return UInt64.max }

    let withImplicit = UInt64(sig | sfImplicitBit)
    if e >= sfSignificandBits {
        return withImplicit << (e &- sfSignificandBits)
    } else {
        return withImplicit >> (sfSignificandBits &- e)
    }
}

// MARK: - Comparisons

@c(__unordsf2)
@inline(never)
public func unordsf2(_ a: Float, _ b: Float) -> Int32 {
    if sfIsNaN(sfToRep(a)) || sfIsNaN(sfToRep(b)) { return 1 }
    return 0
}

@c(__eqsf2)
@inline(never)
public func eqsf2(_ a: Float, _ b: Float) -> Int32 {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)
    if sfIsNaN(aRep) || sfIsNaN(bRep) { return 1 }
    return cmpsf2(aRep, bRep) != 0 ? 1 : 0
}

@c(__nesf2)
@inline(never)
public func nesf2(_ a: Float, _ b: Float) -> Int32 {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)
    if sfIsNaN(aRep) || sfIsNaN(bRep) { return 1 }
    return cmpsf2(aRep, bRep) != 0 ? 1 : 0
}

@c(__ltsf2)
@inline(never)
public func ltsf2(_ a: Float, _ b: Float) -> Int32 {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)
    if sfIsNaN(aRep) || sfIsNaN(bRep) { return 1 }
    return cmpsf2(aRep, bRep)
}

@c(__lesf2)
@inline(never)
public func lesf2(_ a: Float, _ b: Float) -> Int32 {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)
    if sfIsNaN(aRep) || sfIsNaN(bRep) { return 1 }
    return cmpsf2(aRep, bRep)
}

@c(__gtsf2)
@inline(never)
public func gtsf2(_ a: Float, _ b: Float) -> Int32 {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)
    if sfIsNaN(aRep) || sfIsNaN(bRep) { return -1 }
    return cmpsf2(aRep, bRep)
}

@c(__gesf2)
@inline(never)
public func gesf2(_ a: Float, _ b: Float) -> Int32 {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)
    if sfIsNaN(aRep) || sfIsNaN(bRep) { return -1 }
    return cmpsf2(aRep, bRep)
}

// MARK: - __addsf3 — Float Addition

@c(__addsf3)
@inline(never)
public func addsf3(_ a: Float, _ b: Float) -> Float {
    var aRep = sfToRep(a)
    var bRep = sfToRep(b)

    if sfIsNaN(aRep) { return sfFromRep(aRep | sfQuietNaN) }
    if sfIsNaN(bRep) { return sfFromRep(bRep | sfQuietNaN) }

    let aInf = sfIsInf(aRep)
    let bInf = sfIsInf(bRep)
    if aInf && bInf {
        if (aRep ^ bRep) & sfSignBit != 0 { return sfFromRep(sfQuietNaN) }
        return a
    }
    if aInf { return a }
    if bInf { return b }

    if sfIsZero(aRep) {
        if sfIsZero(bRep) { return sfFromRep(aRep & bRep & sfSignBit) }
        return b
    }
    if sfIsZero(bRep) { return a }

    if (aRep & sfAbsMask) < (bRep & sfAbsMask) {
        let tmp = aRep; aRep = bRep; bRep = tmp
    }

    let aSign = aRep & sfSignBit
    let bSign = bRep & sfSignBit
    var aExp = sfExtractBiasedExponent(aRep)
    var bExp = sfExtractBiasedExponent(bRep)
    var aSig = sfExtractSignificand(aRep)
    var bSig = sfExtractSignificand(bRep)

    if aExp != 0 { aSig |= sfImplicitBit } else { aExp = 1 }
    if bExp != 0 { bSig |= sfImplicitBit } else { bExp = 1 }

    let expDiff = aExp &- bExp

    let aSig3 = aSig << 3
    var bSig3 = bSig << 3

    if expDiff > 0 {
        if expDiff < 32 {
            let stickyMask = (UInt32(1) << expDiff) &- 1
            let sticky: UInt32 = (bSig3 & stickyMask) != 0 ? 1 : 0
            bSig3 = (bSig3 >> expDiff) | sticky
        } else {
            bSig3 = 1
        }
    }

    var resultExp = aExp
    var resultSig: UInt32
    let resultSign: UInt32

    if aSign == bSign {
        resultSign = aSign
        resultSig = aSig3 &+ bSig3
        if resultSig & (sfImplicitBit << 4) != 0 {
            let sticky: UInt32 = (resultSig & 1) != 0 ? 1 : 0
            resultSig = (resultSig >> 1) | sticky
            resultExp &+= 1
        }
    } else {
        resultSign = aSign
        resultSig = aSig3 &- bSig3
        if resultSig == 0 { return sfFromRep(0) }
        let targetBit: UInt32 = sfImplicitBit << 3
        while resultSig & targetBit == 0 && resultExp > 1 {
            resultSig <<= 1
            resultExp &-= 1
        }
    }

    let roundBits = resultSig & 0x7
    resultSig >>= 3
    resultSig &= sfSignificandMask

    if roundBits > 4 || (roundBits == 4 && (resultSig & 1) != 0) {
        resultSig &+= 1
        if resultSig > sfSignificandMask {
            resultSig = 0
            resultExp &+= 1
        }
    }

    if resultExp >= 0xFF { return sfFromRep(resultSign | sfInfRep) }
    if resultExp <= 0 { return sfFromRep(resultSign) }

    return sfFromRep(resultSign | UInt32(resultExp) << 23 | resultSig)
}

// MARK: - __subsf3 — Float Subtraction

@c(__subsf3)
@inline(never)
public func subsf3(_ a: Float, _ b: Float) -> Float {
    return addsf3(a, sfFromRep(sfToRep(b) ^ sfSignBit))
}

// MARK: - __mulsf3 — Float Multiplication

@c(__mulsf3)
@inline(never)
public func mulsf3(_ a: Float, _ b: Float) -> Float {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)

    let resultSign = (aRep ^ bRep) & sfSignBit

    if sfIsNaN(aRep) { return sfFromRep(aRep | sfQuietNaN) }
    if sfIsNaN(bRep) { return sfFromRep(bRep | sfQuietNaN) }

    if sfIsInf(aRep) && sfIsZero(bRep) { return sfFromRep(sfQuietNaN) }
    if sfIsZero(aRep) && sfIsInf(bRep) { return sfFromRep(sfQuietNaN) }

    if sfIsInf(aRep) || sfIsInf(bRep) { return sfFromRep(resultSign | sfInfRep) }
    if sfIsZero(aRep) || sfIsZero(bRep) { return sfFromRep(resultSign) }

    var aExp = sfExtractBiasedExponent(aRep)
    var bExp = sfExtractBiasedExponent(bRep)
    var aSig = sfExtractSignificand(aRep)
    var bSig = sfExtractSignificand(bRep)

    if aExp == 0 {
        let shift = Int32((aSig | sfImplicitBit).leadingZeroBitCount) &- 8
        aSig = (aSig << shift) & sfSignificandMask
        aExp = 1 &- shift
    }
    if bExp == 0 {
        let shift = Int32((bSig | sfImplicitBit).leadingZeroBitCount) &- 8
        bSig = (bSig << shift) & sfSignificandMask
        bExp = 1 &- shift
    }

    aSig |= sfImplicitBit
    bSig |= sfImplicitBit

    // 24-bit × 24-bit → 48-bit product (fits in UInt64)
    let product = UInt64(aSig) &* UInt64(bSig)

    var resultExp = aExp &+ bExp &- sfExponentBias

    var resultSig: UInt32
    let roundBit: UInt32
    let stickyBit: Bool

    if product & (1 << 47) != 0 {
        resultSig = UInt32(truncatingIfNeeded: product >> 24)
        roundBit = UInt32(truncatingIfNeeded: (product >> 23) & 1)
        stickyBit = (product & ((1 << 23) &- 1)) != 0
        resultExp &+= 1
    } else {
        resultSig = UInt32(truncatingIfNeeded: product >> 23)
        roundBit = UInt32(truncatingIfNeeded: (product >> 22) & 1)
        stickyBit = (product & ((1 << 22) &- 1)) != 0
    }

    resultSig &= sfSignificandMask

    if roundBit != 0 && (stickyBit || (resultSig & 1) != 0) {
        resultSig &+= 1
        if resultSig > sfSignificandMask {
            resultSig = 0
            resultExp &+= 1
        }
    }

    if resultExp >= 0xFF { return sfFromRep(resultSign | sfInfRep) }
    if resultExp <= 0 { return sfFromRep(resultSign) }

    return sfFromRep(resultSign | UInt32(resultExp) << 23 | resultSig)
}

// MARK: - __divsf3 — Float Division

@c(__divsf3)
@inline(never)
public func divsf3(_ a: Float, _ b: Float) -> Float {
    let aRep = sfToRep(a)
    let bRep = sfToRep(b)

    let resultSign = (aRep ^ bRep) & sfSignBit

    if sfIsNaN(aRep) { return sfFromRep(aRep | sfQuietNaN) }
    if sfIsNaN(bRep) { return sfFromRep(bRep | sfQuietNaN) }

    if sfIsInf(aRep) && sfIsInf(bRep) { return sfFromRep(sfQuietNaN) }
    if sfIsZero(aRep) && sfIsZero(bRep) { return sfFromRep(sfQuietNaN) }

    if sfIsInf(aRep) { return sfFromRep(resultSign | sfInfRep) }
    if sfIsInf(bRep) { return sfFromRep(resultSign) }
    if sfIsZero(bRep) { return sfFromRep(resultSign | sfInfRep) }
    if sfIsZero(aRep) { return sfFromRep(resultSign) }

    var aExp = sfExtractBiasedExponent(aRep)
    var bExp = sfExtractBiasedExponent(bRep)
    var aSig = sfExtractSignificand(aRep)
    var bSig = sfExtractSignificand(bRep)

    if aExp == 0 {
        let shift = Int32((aSig | sfImplicitBit).leadingZeroBitCount) &- 8
        aSig = (aSig << shift) & sfSignificandMask
        aExp = 1 &- shift
    }
    if bExp == 0 {
        let shift = Int32((bSig | sfImplicitBit).leadingZeroBitCount) &- 8
        bSig = (bSig << shift) & sfSignificandMask
        bExp = 1 &- shift
    }

    aSig |= sfImplicitBit
    bSig |= sfImplicitBit

    var resultExp = aExp &- bExp &+ sfExponentBias

    var remainder = aSig
    var quotient: UInt32 = 0

    if remainder >= bSig {
        remainder &-= bSig
        quotient = 1
    } else {
        resultExp &-= 1
    }

    var i: Int32 = 0
    while i < 24 {
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

    let resultSig = quotient & sfSignificandMask

    if roundBit != 0 && ((remainder != 0) || (resultSig & 1) != 0) {
        let rounded = resultSig &+ 1
        if rounded > sfSignificandMask {
            resultExp &+= 1
            if resultExp >= 0xFF { return sfFromRep(resultSign | sfInfRep) }
            return sfFromRep(resultSign | UInt32(resultExp) << 23)
        }
        return sfFromRep(resultSign | UInt32(resultExp) << 23 | rounded)
    }

    if resultExp >= 0xFF { return sfFromRep(resultSign | sfInfRep) }
    if resultExp <= 0 { return sfFromRep(resultSign) }

    return sfFromRep(resultSign | UInt32(resultExp) << 23 | resultSig)
}

// MARK: - ceilf — Ceiling Function

@c(ceilf)
@inline(never)
public func ceilfImpl(_ x: Float) -> Float {
    let rep = sfToRep(x)
    let biasedExp = sfExtractBiasedExponent(rep)

    if biasedExp >= sfExponentBias &+ sfSignificandBits { return x }

    if biasedExp < sfExponentBias {
        if sfIsZero(rep) { return x }
        if (rep & sfSignBit) != 0 { return sfFromRep(sfSignBit) }
        return sfFromRep(0x3F80_0000)  // 1.0f
    }

    let e = biasedExp &- sfExponentBias
    let fracMask = sfSignificandMask >> e

    if (rep & fracMask) == 0 { return x }

    if (rep & sfSignBit) == 0 {
        return sfFromRep((rep | fracMask) &+ 1)
    } else {
        return sfFromRep(rep & ~fracMask)
    }
}

// MARK: - floorf — Floor Function

@c(floorf)
@inline(never)
public func floorfImpl(_ x: Float) -> Float {
    let rep = sfToRep(x)
    let biasedExp = sfExtractBiasedExponent(rep)

    if biasedExp >= sfExponentBias &+ sfSignificandBits { return x }

    if biasedExp < sfExponentBias {
        if sfIsZero(rep) { return x }
        if (rep & sfSignBit) != 0 { return sfFromRep(0xBF80_0000) }  // -1.0f
        return sfFromRep(0)
    }

    let e = biasedExp &- sfExponentBias
    let fracMask = sfSignificandMask >> e

    if (rep & fracMask) == 0 { return x }

    if (rep & sfSignBit) != 0 {
        return sfFromRep((rep | fracMask) &+ 1)
    } else {
        return sfFromRep(rep & ~fracMask)
    }
}

// MARK: - __extendsfdf2 — Float → Double

@c(__extendsfdf2)
@inline(never)
public func extendsfdf2(_ a: Float) -> Double {
    let rep = sfToRep(a)

    if sfIsNaN(rep) {
        let sig = UInt64(sfExtractSignificand(rep)) << 29
        return Double(bitPattern: 0x7FF0_0000_0000_0000 | UInt64(rep & sfSignBit) << 32 | sig | 0x0008_0000_0000_0000)
    }

    if sfIsInf(rep) {
        return Double(bitPattern: UInt64(rep & sfSignBit) << 32 | 0x7FF0_0000_0000_0000)
    }

    if sfIsZero(rep) {
        return Double(bitPattern: UInt64(rep & sfSignBit) << 32)
    }

    let sign = UInt64(rep & sfSignBit) << 32
    var exp = sfExtractBiasedExponent(rep)
    var sig = sfExtractSignificand(rep)

    if exp == 0 {
        let shift = Int32(sig.leadingZeroBitCount) &- 8
        sig = (sig << shift) & sfSignificandMask
        exp = 1 &- shift
    }

    let dExp = Int32(exp) &- sfExponentBias &+ 1023
    let dSig = UInt64(sig) << 29

    return Double(bitPattern: sign | (UInt64(dExp) << 52) | dSig)
}

// MARK: - __truncdfsf2 — Double → Float

@c(__truncdfsf2)
@inline(never)
public func truncdfsf2(_ a: Double) -> Float {
    let rep = a.bitPattern

    let sign = UInt32(rep >> 32) & 0x8000_0000

    if (rep & 0x7FFF_FFFF_FFFF_FFFF) > 0x7FF0_0000_0000_0000 {
        return sfFromRep(sign | sfQuietNaN)
    }

    if (rep & 0x7FFF_FFFF_FFFF_FFFF) == 0x7FF0_0000_0000_0000 {
        return sfFromRep(sign | sfInfRep)
    }

    if (rep & 0x7FFF_FFFF_FFFF_FFFF) == 0 {
        return sfFromRep(sign)
    }

    var dExp = Int32((rep >> 52) & 0x7FF)
    var dSig = rep & 0x000F_FFFF_FFFF_FFFF

    if dExp == 0 {
        let shift = Int32(dSig.leadingZeroBitCount) &- 11
        dSig = (dSig << shift) & 0x000F_FFFF_FFFF_FFFF
        dExp = 1 &- shift
    }

    var sExp = dExp &- 1023 &+ sfExponentBias

    if sExp >= 0xFF { return sfFromRep(sign | sfInfRep) }
    if sExp <= 0 { return sfFromRep(sign) }

    let roundBit = UInt32(truncatingIfNeeded: (dSig >> 28) & 1)
    let stickyMask = (UInt64(1) << 28) &- 1
    let sticky: UInt32 = (dSig & stickyMask) != 0 ? 1 : 0

    var sSig = UInt32(truncatingIfNeeded: dSig >> 29) & sfSignificandMask

    if roundBit != 0 && (sticky != 0 || (sSig & 1) != 0) {
        sSig &+= 1
        if sSig > sfSignificandMask {
            sSig = 0
            sExp &+= 1
            if sExp >= 0xFF { return sfFromRep(sign | sfInfRep) }
        }
    }

    return sfFromRep(sign | UInt32(sExp) << 23 | sSig)
}
