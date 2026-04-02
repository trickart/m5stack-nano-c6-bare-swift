# Task 11: Hardware RNG & Hashable Support

## Overview

Enable the ESP32-C6 hardware RNG by configuring the SAR ADC as an entropy source, and provide `arc4random_buf` backed by a ChaCha20 CSPRNG so that Embedded Swift's `Hashable` protocol works on bare metal.

Files:
- `Sources/Application/Support/Random.swift` — SAR ADC entropy source init, ChaCha20 CSPRNG state + `arc4random_buf`
- `Sources/Application/Support/ChaCha20.swift` — ChaCha20 block cipher implementation
- `Sources/MemoryPrimitives/MemoryPrimitives.swift` — 64-bit shift helpers (`__ashldi3` / `__lshrdi3`)

## Why This Is Needed

Embedded Swift's `Hashable` protocol (used by `Dictionary`, `Set`, `enum` pattern matching, etc.) internally calls `arc4random_buf` to seed `Hasher` with random bytes. On bare metal with `-nostdlib`, this symbol is undefined and causes a link error.

Additionally, `Hasher._combine` performs 64-bit arithmetic. On RV32 (32-bit RISC-V), the compiler emits calls to `__ashldi3` (64-bit left shift) and `__lshrdi3` (64-bit logical right shift) from compiler-rt, which are also missing without a standard library.

## ESP32-C6 Hardware RNG

The ESP32-C6 has a hardware random number generator accessible via a single register:

| Register | Address | Description |
|----------|---------|-------------|
| `LPPERI_RNG_DATA_REG` | `0x600B_2808` | 32-bit read-only; returns a new random value on each read |

However, the RNG requires an active noise source to produce true random numbers. Without one, the output is pseudo-random and may have poor entropy. The two possible noise sources are:

1. **RF subsystem** (Wi-Fi / Bluetooth) — not available in this bare-metal project
2. **SAR ADC** — can be enabled independently

Reference: [ESP-IDF Random Number Generation](https://docs.espressif.com/projects/esp-idf/en/stable/esp32c6/api-reference/system/random.html)

## SAR ADC Entropy Source Initialization

Ported from ESP-IDF's `bootloader_random_esp32c6.c`. Called once at startup via `enableEntropySource()`.

### Register Map

| Register | Address | Key Bits |
|----------|---------|----------|
| `PCR_SARADC_CONF_REG` | `0x6009_6080` | bit 1: RST_EN, bit 2: REG_CLK_EN |
| `PCR_SARADC_CLKM_CONF_REG` | `0x6009_6084` | bit 22: CLKM_EN, bits 21:20: CLKM_SEL, bits 19:12: DIV_NUM |
| `PMU_RF_PWC_REG` | `0x600B_0154` | bit 26: PERIF_I2C_RSTB, bit 27: XPD_PERIF_I2C |
| `ANA_CONFIG_REG` | `0x600A_F81C` | bit 18: I2C_SAR_FORCE_PD |
| `ANA_CONFIG2_REG` | `0x600A_F820` | bit 16: I2C_SAR_FORCE_PU |
| `APB_SARADC_CTRL_REG` | `0x6000_E000` | bits 14:7: SAR_CLK_DIV, bits 17:15: SAR_PATT_LEN |
| `APB_SARADC_CTRL2_REG` | `0x6000_E004` | bits 23:12: TIMER_TARGET, bit 24: TIMER_EN |
| `APB_SARADC_SAR_PATT_TAB1_REG` | `0x6000_E018` | Pattern table entries |

### Initialization Sequence

1. **Reset SAR ADC** — toggle RST_EN in `PCR_SARADC_CONF_REG`
2. **Enable clocks** — APB clock (REG_CLK_EN) and function clock (CLKM_EN) with XTAL (40 MHz) source
3. **Power up PERIF_I2C** — set RSTB and XPD bits in `PMU_RF_PWC_REG`
4. **Enable SAR I2C bus** — clear force-PD, set force-PU in analog config registers
5. **Configure ADC internals via I2C** — 8 register writes to set internal voltage as sampling source
6. **Set pattern table** — channel 9 with attenuation 1 (two entries)
7. **Start continuous conversion** — SAR CLK divider=15, timer target=200, enable timer

### I2C Analog Master

The SAR ADC's internal calibration registers are not memory-mapped. They are accessed through an I2C analog master peripheral:

| Register | Address | Description |
|----------|---------|-------------|
| `I2C_ANA_MST_I2C0_CTRL_REG` | `0x600A_F800` | I2C channel 0 control |
| `I2C_ANA_MST_I2C1_CTRL_REG` | `0x600A_F804` | I2C channel 1 control |
| `I2C_ANA_MST_ANA_CONF1_REG` | `0x600A_F81C` | Slave read-enable mask |
| `I2C_ANA_MST_ANA_CONF2_REG` | `0x600A_F820` | Master channel select |
| `MODEM_LPCON_CLK_CONF_REG` | `0x600A_F018` | bit 2: I2C master clock enable |
| `MODEM_LPCON_I2C_MST_CLK_CONF` | `0x600A_F010` | bit 0: 160MHz clock select |

The I2C control register layout (32-bit):

```
bits  7:0  = slave_id (0x69 for SAR ADC)
bits 15:8  = register address
bits 23:16 = data (write) / readback (read)
bit  24    = wr_cntl (0=read, 1=write)
bit  25    = busy (read-only, poll until 0)
```

The write-mask protocol (read-modify-write):
1. Enable I2C master clock via MODEM_LPCON
2. Read ANA_CONF2 bit 11 to select I2C channel (0 or 1)
3. Write slave read-enable mask to ANA_CONF1
4. Poll busy → write read command → poll busy → extract data
5. Apply bit mask, compose write command → poll busy

Ported from ESP-IDF's `esp_rom_hp_regi2c_esp32c6.c`.

## ChaCha20 CSPRNG

Rather than reading the hardware RNG register directly for every `arc4random_buf` call, we use a ChaCha20-based CSPRNG (cryptographically secure pseudo-random number generator). The hardware RNG seeds the CSPRNG, and ChaCha20 generates the output bytes.

### Why ChaCha20?

- **Quality**: ChaCha20 output is computationally indistinguishable from true random, passing all statistical tests regardless of output volume
- **Speed**: A single HW RNG seed produces a stream of high-quality bytes without per-byte register reads
- **Robustness**: Output quality does not depend on entropy accumulation timing — eliminates the risk of correlated outputs from back-to-back hardware register reads

### ChaCha20 Block Cipher (`ChaCha20.swift`)

Standard ChaCha20 per [RFC 7539](https://datatracker.ietf.org/doc/html/rfc7539):

- 16 × 32-bit word state: 4 constants ("expand 32-byte k") + 8 key words + 1 counter + 3 nonce words
- Quarter round: ARX (add-rotate-xor) operations with rotations of 16, 12, 8, 7 bits
- 10 double rounds (20 rounds total): alternating column and diagonal quarter rounds
- Final addition of the initial state to the working state

### CSPRNG State Management (`Random.swift`)

Global state (marked `nonisolated(unsafe)` for bare-metal single-threaded use):

| Variable | Type | Description |
|----------|------|-------------|
| `csprngState` | 16 × UInt32 tuple | ChaCha20 input state (constants + key + counter + nonce) |
| `csprngBuffer` | 16 × UInt32 tuple | 64-byte output buffer |
| `csprngBufPos` | Int | Bytes consumed from current buffer (starts at 64 to force initial generation) |
| `csprngBlockCount` | UInt32 | Blocks generated since last reseed |

### Seeding

`seedCsprng()` reads 11 words from the hardware RNG:
- 8 words → key (256 bits of entropy)
- 3 words → nonce (96 bits)
- Counter is reset to 0

### Reseeding

After every 16,384 blocks (~1 MB of output), the CSPRNG automatically reseeds from the hardware RNG, limiting the window of exposure if the key were ever compromised.

### arc4random_buf

```swift
@c(arc4random_buf)
public func arc4random_buf(_ buf: UnsafeMutableRawPointer, _ nbytes: Int)
```

Fills the buffer from the ChaCha20 output buffer. When the buffer is exhausted (every 64 bytes), a new ChaCha20 block is generated and the counter is incremented.

### Dieharder Test Results

Verified with the [Dieharder](https://github.com/eddelbuettel/dieharder) random number test suite (114 tests, 1 GB sample):

| Assessment | Count |
|------------|-------|
| PASSED | 110 |
| WEAK | 4 |
| FAILED | 0 |

The 4 WEAK results are within the expected statistical noise (~5% of 114 tests ≈ 5.7 expected).

## 64-bit Shift Helpers

`Hasher._combine` uses 64-bit operations. On RV32, the compiler emits calls to compiler-rt functions:

| Symbol | Purpose |
|--------|---------|
| `__ashldi3` | 64-bit left shift (`uint64 << int`) |
| `__lshrdi3` | 64-bit logical right shift (`uint64 >> int`) |

### Avoiding Infinite Recursion

These must be implemented using **only 32-bit operations**. If the implementation contains any 64-bit shift (e.g., `UInt64(hi) << 32`), the compiler will emit a recursive call to the very function being defined, causing a stack overflow.

The solution is to split/construct UInt64 values via pointer access to the two UInt32 halves (little-endian on RISC-V):

```swift
@inline(__always)
private func split64(_ value: UInt64) -> (lo: UInt32, hi: UInt32) {
    var v = value
    return withUnsafePointer(to: &v) { ptr in
        let p = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        return (p[0], p[1])
    }
}

@inline(__always)
private func make64(lo: UInt32, hi: UInt32) -> UInt64 {
    var result: UInt64 = 0
    withUnsafeMutablePointer(to: &result) { ptr in
        let p = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        p[0] = lo
        p[1] = hi
    }
    return result
}
```

The shift logic then operates on 32-bit halves only, with three cases: shift >= 32, shift == 0, and 0 < shift < 32.

## Startup Integration

`enableEntropySource()` and `seedCsprng()` are called in `Application.main()` immediately after `disableWatchdogs()`:

```swift
static func main() {
    clearBSS()
    disableWatchdogs()
    enableEntropySource()
    seedCsprng()
    // ... application code (Hashable now works)
}
```

The SAR ADC clock (XTAL, 40 MHz) is independent of the CPU clock (PLL, 160 MHz) — enabling it has no effect on CPU performance.

## ESP-IDF Source References

| File | Purpose |
|------|---------|
| `components/bootloader_support/src/bootloader_random_esp32c6.c` | SAR ADC init sequence |
| `components/esp_rom/patches/esp_rom_hp_regi2c_esp32c6.c` | I2C analog master protocol |
| `components/soc/esp32c6/include/soc/regi2c_saradc.h` | SAR ADC I2C register definitions |
| `components/soc/esp32c6/include/soc/reg_base.h` | Peripheral base addresses |
