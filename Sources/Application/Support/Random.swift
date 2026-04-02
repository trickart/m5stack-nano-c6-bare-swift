// MARK: - I2C Analog Master registers

private let MODEM_LPCON_CLK_CONF_REG: UInt32       = 0x600A_F018
private let MODEM_LPCON_I2C_MST_CLK_CONF: UInt32   = 0x600A_F010
private let I2C_ANA_MST_I2C0_CTRL_REG: UInt32      = 0x600A_F800
private let I2C_ANA_MST_ANA_CONF1_REG: UInt32      = 0x600A_F81C
private let I2C_ANA_MST_ANA_CONF2_REG: UInt32      = 0x600A_F820

// MARK: - SAR ADC clock and control registers

private let PCR_SARADC_CONF_REG: UInt32             = 0x6009_6080
private let PCR_SARADC_CLKM_CONF_REG: UInt32        = 0x6009_6084
private let PMU_RF_PWC_REG: UInt32                   = 0x600B_0154
private let APB_SARADC_CTRL_REG: UInt32              = 0x6000_E000
private let APB_SARADC_CTRL2_REG: UInt32             = 0x6000_E004
private let APB_SARADC_SAR_PATT_TAB1_REG: UInt32     = 0x6000_E018

// MARK: - RNG data register

private let LPPERI_RNG_DATA_REG: UInt32              = 0x600B_2808

// MARK: - I2C Analog Master (SAR ADC internal register access)

/// Enable the I2C analog master block for SAR ADC and return the I2C channel (0 or 1).
private func regi2cEnableBlock() -> UInt8 {
    // Enable I2C master clock
    regStore(MODEM_LPCON_CLK_CONF_REG,
             regLoad(MODEM_LPCON_CLK_CONF_REG) | (1 << 2))        // CLK_I2C_MST_EN
    regStore(MODEM_LPCON_I2C_MST_CLK_CONF,
             regLoad(MODEM_LPCON_I2C_MST_CLK_CONF) | (1 << 0))    // CLK_I2C_MST_SEL_160M

    // Select I2C channel based on SAR I2C master select bit (bit 11)
    let i2cSel = regLoad(I2C_ANA_MST_ANA_CONF2_REG) & (1 << 11)

    // Write SAR I2C read-enable mask: ~BIT(9) & 0xFFFFFF
    regStore(I2C_ANA_MST_ANA_CONF1_REG, ~UInt32(1 << 9) & 0x00FF_FFFF)

    return i2cSel != 0 ? 0 : 1
}

/// Wait for the I2C analog master busy bit to clear.
@inline(__always)
private func regi2cWaitIdle(_ ctrlReg: UInt32) {
    while regLoad(ctrlReg) & (1 << 25) != 0 {}
}

/// Write a masked value to an internal analog register via I2C master.
/// Implements read-modify-write following ESP-IDF regi2c_write_mask_impl.
private func regi2cWriteMask(regAddr: UInt8, msb: UInt8, lsb: UInt8, data: UInt8) {
    let slaveId: UInt32 = 0x69  // I2C_SAR_ADC
    let i2cSel = regi2cEnableBlock()
    let ctrlReg = I2C_ANA_MST_I2C0_CTRL_REG + UInt32(i2cSel) * 4

    // Read current register value
    regi2cWaitIdle(ctrlReg)
    let readCmd = (slaveId << 0) | (UInt32(regAddr) << 8)
    regStore(ctrlReg, readCmd)
    regi2cWaitIdle(ctrlReg)
    var regVal = (regLoad(ctrlReg) >> 16) & 0xFF

    // Modify bits [msb:lsb]
    let mask = ~(~(UInt32(0xFFFF_FFFF) << lsb) | (UInt32(0xFFFF_FFFF) << (msb + 1)))
    regVal = (regVal & ~mask) | ((UInt32(data) & (~(UInt32(0xFFFF_FFFF) << (msb - lsb + 1)))) << lsb)

    // Write back
    let writeCmd = (slaveId << 0)
        | (UInt32(regAddr) << 8)
        | (regVal << 16)
        | (1 << 24)  // wr_cntl
    regStore(ctrlReg, writeCmd)
    regi2cWaitIdle(ctrlReg)
}

// MARK: - Entropy source initialization

/// Enable the SAR ADC as an entropy source for the hardware RNG.
/// Must be called before any use of arc4random_buf.
/// Ported from ESP-IDF bootloader_random_esp32c6.c.
func enableEntropySource() {
    // 1. Pull SAR ADC out of reset
    regStore(PCR_SARADC_CONF_REG, regLoad(PCR_SARADC_CONF_REG) | (1 << 1))   // RST_EN
    regStore(PCR_SARADC_CONF_REG, regLoad(PCR_SARADC_CONF_REG) & ~(1 << 1))  // clear RST_EN

    // 2. Enable SAR ADC APB clock
    regStore(PCR_SARADC_CONF_REG, regLoad(PCR_SARADC_CONF_REG) | (1 << 2))   // REG_CLK_EN

    // 3. Enable ADC_CTRL_CLK (function clock)
    regStore(PCR_SARADC_CLKM_CONF_REG,
             regLoad(PCR_SARADC_CLKM_CONF_REG) | (1 << 22))                  // CLKM_EN

    // 4. Select XTAL clock source (bits 21:20 = 0), divider = 0 (bits 19:12 = 0)
    var clkm = regLoad(PCR_SARADC_CLKM_CONF_REG)
    clkm &= ~(0x3 << 20)          // CLKM_SEL = 0
    clkm &= ~(0xFF << 12)         // CLKM_DIV_NUM = 0
    regStore(PCR_SARADC_CLKM_CONF_REG, clkm)

    // 5. Power up PERIF_I2C via PMU
    regStore(PMU_RF_PWC_REG, regLoad(PMU_RF_PWC_REG) | (1 << 26))  // PERIF_I2C_RSTB
    regStore(PMU_RF_PWC_REG, regLoad(PMU_RF_PWC_REG) | (1 << 27))  // XPD_PERIF_I2C

    // 6. Enable SAR I2C bus power
    // ANA_CONFIG_REG (0x600AF81C) bit 18: clear SAR force power-down
    regStore(I2C_ANA_MST_ANA_CONF1_REG,
             regLoad(I2C_ANA_MST_ANA_CONF1_REG) & ~(1 << 18))
    // ANA_CONFIG2_REG (0x600AF820) bit 16: set SAR force power-up
    regStore(I2C_ANA_MST_ANA_CONF2_REG,
             regLoad(I2C_ANA_MST_ANA_CONF2_REG) | (1 << 16))

    // 7. Configure SAR ADC internal registers via I2C
    regi2cWriteMask(regAddr: 0x7, msb: 1, lsb: 0, data: 2)     // DTEST_RTC: internal voltage source
    regi2cWriteMask(regAddr: 0x7, msb: 3, lsb: 3, data: 1)     // ENT_RTC: enable RTC ADC
    regi2cWriteMask(regAddr: 0x7, msb: 4, lsb: 4, data: 1)     // SAR1_ENCAL_REF
    regi2cWriteMask(regAddr: 0x7, msb: 6, lsb: 6, data: 1)     // SAR2_ENCAL_REF
    regi2cWriteMask(regAddr: 0x4, msb: 3, lsb: 0, data: 0x08)  // SAR2 initial code high
    regi2cWriteMask(regAddr: 0x3, msb: 7, lsb: 0, data: 0x66)  // SAR2 initial code low
    regi2cWriteMask(regAddr: 0x1, msb: 3, lsb: 0, data: 0x08)  // SAR1 initial code high
    regi2cWriteMask(regAddr: 0x0, msb: 7, lsb: 0, data: 0x66)  // SAR1 initial code low

    // 8. Pattern table: channel 9 with attenuation 1 (two entries)
    let patternOne: UInt32 = (9 << 2) | 1   // 0x25
    let patternTwo: UInt32 = 1               // channel 0, atten 1
    let patternTable = (patternTwo << 18) | (patternOne << 12)
    regStore(APB_SARADC_SAR_PATT_TAB1_REG, patternTable)

    // 9. Pattern length = 1 (2 entries), SAR CLK divider = 15
    var ctrl = regLoad(APB_SARADC_CTRL_REG)
    ctrl &= ~(0x7 << 15)                    // clear PATT_LEN
    ctrl |= (1 << 15)                       // PATT_LEN = 1
    ctrl &= ~(0xFF << 7)                    // clear SAR_CLK_DIV
    ctrl |= (15 << 7)                       // SAR_CLK_DIV = 15
    regStore(APB_SARADC_CTRL_REG, ctrl)

    // 10. Timer target = 200, enable timer
    var ctrl2 = regLoad(APB_SARADC_CTRL2_REG)
    ctrl2 &= ~(0xFFF << 12)                 // clear TIMER_TARGET
    ctrl2 |= (200 << 12)                    // TIMER_TARGET = 200
    ctrl2 |= (1 << 24)                      // TIMER_EN
    regStore(APB_SARADC_CTRL2_REG, ctrl2)
}

// MARK: - Direct hardware RNG read

/// Read one 32-bit random value from the hardware RNG register.
func readRandom32() -> UInt32 {
    regLoad(LPPERI_RNG_DATA_REG)
}

// MARK: - ChaCha20 CSPRNG state

// Input state: [0-3] constants, [4-11] key, [12] counter, [13-15] nonce
nonisolated(unsafe) private var csprngState: (
    UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32
) = (
    0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

// Output buffer (64 bytes)
nonisolated(unsafe) private var csprngBuffer: (
    UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32,
    UInt32, UInt32, UInt32, UInt32
) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

nonisolated(unsafe) private var csprngBufPos: Int = 64  // Bytes consumed; starts exhausted
nonisolated(unsafe) private var csprngBlockCount: UInt32 = 0

/// Seed the ChaCha20 CSPRNG from the hardware RNG.
/// Must be called after enableEntropySource().
func seedCsprng() {
    withUnsafeMutablePointer(to: &csprngState) { ptr in
        let s = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        for i in 4..<12 {
            s[i] = regLoad(LPPERI_RNG_DATA_REG)
        }
        s[12] = 0
        for i in 13..<16 {
            s[i] = regLoad(LPPERI_RNG_DATA_REG)
        }
    }
    csprngBufPos = 64
    csprngBlockCount = 0
}

private func generateCsprngBlock() {
    // Reseed every ~1MB (16384 blocks x 64 bytes)
    if csprngBlockCount >= 16384 {
        seedCsprng()
    }

    withUnsafeMutablePointer(to: &csprngState) { statePtr in
        let state = UnsafeMutableRawPointer(statePtr).assumingMemoryBound(to: UInt32.self)
        withUnsafeMutablePointer(to: &csprngBuffer) { bufPtr in
            let buf = UnsafeMutableRawPointer(bufPtr).assumingMemoryBound(to: UInt32.self)
            chacha20Block(state, buf)
        }
        state[12] &+= 1
    }
    csprngBufPos = 0
    csprngBlockCount &+= 1
}

// MARK: - arc4random_buf

@c(arc4random_buf)
public func arc4random_buf(_ buf: UnsafeMutableRawPointer, _ nbytes: Int) {
    let dst = buf.assumingMemoryBound(to: UInt8.self)
    var offset = 0
    while offset < nbytes {
        if csprngBufPos >= 64 {
            generateCsprngBlock()
        }

        let available = 64 &- csprngBufPos
        let needed = nbytes &- offset
        let toCopy = available < needed ? available : needed

        withUnsafePointer(to: &csprngBuffer) { bufPtr in
            let src = UnsafeRawPointer(bufPtr).assumingMemoryBound(to: UInt8.self)
            for i in 0..<toCopy {
                dst[offset &+ i] = src[csprngBufPos &+ i]
            }
        }

        offset &+= toCopy
        csprngBufPos &+= toCopy
    }
}
