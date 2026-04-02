# Task 12: Software Floating-Point Builtins

## Overview

ESP32-C6 (RV32IMC) has no hardware FPU. This module provides complete IEEE 754 software floating-point support for both double-precision (64-bit) and single-precision (32-bit), plus precision conversions and math functions.

Files:
- `Sources/SoftFloat/SoftDouble.swift` — Double-precision builtins
- `Sources/SoftFloat/SoftFloat.swift` — Single-precision builtins + Float↔Double conversion

## Implemented Functions

### Double-Precision (64-bit)

| Category | Function | Description |
|----------|----------|-------------|
| Conversion | `__floatunsidf` | UInt32 → Double |
| | `__floatsidf` | Int32 → Double |
| | `__floatundidf` | UInt64 → Double (with rounding) |
| | `__floatdidf` | Int64 → Double (with rounding) |
| | `__fixdfsi` | Double → Int32 (truncate toward zero) |
| | `__fixunsdfsi` | Double → UInt32 |
| | `__fixdfdi` | Double → Int64 |
| | `__fixunsdfdi` | Double → UInt64 |
| Comparison | `__unorddf2` | NaN detection |
| | `__eqdf2` / `__nedf2` | Equality / inequality |
| | `__ltdf2` / `__ledf2` | Less than / less-or-equal |
| | `__gtdf2` / `__gedf2` | Greater than / greater-or-equal |
| Arithmetic | `__adddf3` | Addition |
| | `__subdf3` | Subtraction (negates b, delegates to add) |
| | `__muldf3` | Multiplication (128-bit wide multiply) |
| | `__divdf3` | Division (restoring long division) |
| Math | `ceil` | Ceiling function |
| | `floor` | Floor function |

### Single-Precision (32-bit)

| Category | Function | Description |
|----------|----------|-------------|
| Conversion | `__floatunsisf` | UInt32 → Float (with rounding) |
| | `__floatsisf` | Int32 → Float (with rounding) |
| | `__floatundisf` | UInt64 → Float |
| | `__floatdisf` | Int64 → Float |
| | `__fixsfsi` | Float → Int32 |
| | `__fixunssfsi` | Float → UInt32 |
| | `__fixsfdi` | Float → Int64 |
| | `__fixunssfdi` | Float → UInt64 |
| Comparison | `__unordsf2` | NaN detection |
| | `__eqsf2` / `__nesf2` | Equality / inequality |
| | `__ltsf2` / `__lesf2` | Less than / less-or-equal |
| | `__gtsf2` / `__gesf2` | Greater than / greater-or-equal |
| Arithmetic | `__addsf3` | Addition |
| | `__subsf3` | Subtraction |
| | `__mulsf3` | Multiplication (48-bit product in UInt64) |
| | `__divsf3` | Division (restoring long division) |
| Math | `ceilf` | Ceiling function |
| | `floorf` | Floor function |

### Precision Conversion

| Function | Description |
|----------|-------------|
| `__extendsfdf2` | Float → Double (always exact) |
| `__truncdfsf2` | Double → Float (with rounding) |

## IEEE 754 Format Reference

### Double-Precision (64-bit)

```
Bit 63      : Sign (0 = positive, 1 = negative)
Bits 62–52  : Exponent (11 bits, bias = 1023)
Bits 51–0   : Significand (52 bits, with implicit leading 1)
```

Key constants: exponent bias 1023, significand bits 52, implicit bit `0x0010_0000_0000_0000`.

### Single-Precision (32-bit)

```
Bit 31      : Sign
Bits 30–23  : Exponent (8 bits, bias = 127)
Bits 22–0   : Significand (23 bits, with implicit leading 1)
```

Key constants: exponent bias 127, significand bits 23, implicit bit `0x0080_0000`.

## Implementation Notes

### Target Layout

Implemented in a dedicated `SoftFloat` target, separate from `MemoryPrimitives`. Double-precision functions are in `SoftDouble.swift`, single-precision and conversion functions in `SoftFloat.swift`.

The `SoftFloat` target has its own copy of `split64()` / `make64()` helpers for 64-bit decomposition on RV32. An additional `__ashrdi3` (64-bit arithmetic right shift) was added to `MemoryPrimitives` as `ceil` requires signed right shifts.

### Key Algorithms

**Addition (`__adddf3` / `__addsf3`):** Aligns exponents by shifting the smaller operand's significand right, adds or subtracts magnitudes based on sign, normalizes the result, and rounds. Uses 3 extra guard/round/sticky bits for correct rounding.

**Multiplication (`__muldf3`):** On RV32, the 53×53-bit significand multiplication requires a 128-bit product. This is decomposed into four 32×32→64 widening multiplies via `mulhi64()`. Single-precision multiplication (`__mulsf3`) is simpler — the 24×24-bit product fits in a single UInt64.

**Division (`__divdf3` / `__divsf3`):** Uses restoring long division rather than Newton-Raphson, producing 54 bits (double) or 25 bits (single) of quotient. Simpler to implement correctly, with deterministic execution (~400 RV32 instructions for double).

**ceil / floor:** Bit-manipulation trick — compute a mask of fractional bits, then for ceil on positive values: `(rep | fracMask) + 1` carries through all fractional bits into the integer part. For floor, the logic is reversed.

### 64-bit Arithmetic on RV32

All UInt64 operations compile to pairs of 32-bit instructions. The `split64()` / `make64()` helpers use pointer-based decomposition to avoid recursive calls to shift builtins. 64-bit shifts use the existing `__ashldi3` / `__lshrdi3` / `__ashrdi3` builtins in `MemoryPrimitives`.

### Rounding

All arithmetic functions implement IEEE 754 round-to-nearest, ties-to-even. Int-to-float conversions that lose precision (e.g. large Int32 → Float with only 23 bits of significand) also round correctly.

## References

- [LLVM compiler-rt builtins](https://github.com/llvm/llvm-project/tree/main/compiler-rt/lib/builtins)
- [LLVM compiler-rt fp_lib.h](https://github.com/llvm/llvm-project/blob/main/compiler-rt/lib/builtins/fp_lib.h) — IEEE 754 constants and helpers
- [IEEE 754 Double-Precision Format](https://en.wikipedia.org/wiki/Double-precision_floating-point_format)
- [IEEE 754 Single-Precision Format](https://en.wikipedia.org/wiki/Single-precision_floating-point_format)
