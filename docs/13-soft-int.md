# Task 13: Software Integer Arithmetic Builtins

## Overview

ESP32-C6 (RV32IMC) has 32-bit hardware multiply but no 64-bit divide instruction. When the compiler needs 64-bit multiplication, division, or modulo, it emits calls to compiler-rt builtins (`__muldi3`, `__udivdi3`, etc.). Since we link with `-nostdlib`, these must be provided manually.

File:
- `Sources/SoftInt/SoftInt.swift` — 64-bit integer arithmetic builtins

## Why This Is Needed

Any Swift code that triggers 64-bit arithmetic — such as `String(someInt)`, which internally divides by 10 to extract digits — will fail to link without these builtins. The 64-bit shift builtins (`__ashldi3`, `__lshrdi3`, `__ashrdi3`) were already provided in `MemoryPrimitives`; this module adds the remaining arithmetic operations.

## Implemented Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `__muldi3` | `(UInt64, UInt64) → UInt64` | 64-bit multiplication |
| `__udivdi3` | `(UInt64, UInt64) → UInt64` | 64-bit unsigned division |
| `__umoddi3` | `(UInt64, UInt64) → UInt64` | 64-bit unsigned modulo |
| `__divdi3` | `(UInt64, UInt64) → UInt64` | 64-bit signed division |
| `__moddi3` | `(UInt64, UInt64) → UInt64` | 64-bit signed modulo |

## Implementation Details

### 64-bit ↔ 32-bit Decomposition

Like `MemoryPrimitives` and `SoftFloat`, this module uses `split64()` / `make64()` helpers to decompose UInt64 values into (lo, hi) UInt32 pairs via pointer reinterpretation. This avoids emitting 64-bit operations that would recursively call back into the builtins.

### Multiplication (`__muldi3`)

Decomposes the 64×64-bit multiply into 32-bit parts:

```
a * b = (aHi·2³² + aLo) × (bHi·2³² + bLo)
      = aLo·bLo + (aLo·bHi + aHi·bLo)·2³²
```

The `aHi·bHi·2⁶⁴` term overflows and is discarded. The low 32×32→64 multiply uses `UInt32.multipliedFullWidth(by:)` to get the full 64-bit result without triggering `__muldi3` recursion. Cross terms only need the low 32 bits since the upper halves overflow past 64 bits.

### Division (`__udivdi3` / `__umoddi3`)

Uses binary long division (restoring algorithm), iterating over 64 bits:

1. For each bit position (63 down to 0): shift the remainder left by 1, bring down the next dividend bit
2. If remainder ≥ divisor: subtract divisor from remainder, set the corresponding quotient bit

All comparisons and subtractions use 32-bit halves. A fast path handles the common case where both operands fit in 32 bits, using hardware division directly.

### Signed Division (`__divdi3` / `__moddi3`)

Converts operands to absolute values, delegates to the unsigned division, then applies sign correction:
- **Quotient sign:** negative if operand signs differ
- **Remainder sign:** follows the dividend sign (C/Swift semantics)

Two's complement negation (`negate64`) is implemented with 32-bit ops: `~lo + 1` for the low half, `~hi + carry` for the high half.

## Target Layout

`SoftInt` is a separate SwiftPM target with no dependencies, following the same isolation pattern as `SoftFloat` and `MemoryPrimitives`. It is linked into both the `Application` target.

All functions use `@c(symbol_name)` to export the C symbol and `@inline(never)` to prevent the compiler from inlining the body and potentially re-emitting the same 64-bit operations.

## References

- [LLVM compiler-rt builtins](https://github.com/llvm/llvm-project/tree/main/compiler-rt/lib/builtins) — Reference implementations
- [GCC libgcc integer library routines](https://gcc.gnu.org/onlinedocs/gccint/Integer-library-routines.html) — ABI specification
