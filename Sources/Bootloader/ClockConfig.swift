// PLL clock initialization for ESP32-C6.
//
// Switches CPU clock from XTAL (~20-40MHz) to 160MHz PLL.
// Must be called after disableWatchdogs() and before configureFlashSPI().
//
// The ROM bootloader leaves BBPLL already calibrated but switches the CPU
// back to XTAL before jumping to the 2nd stage. We re-enable PLL power
// and switch the CPU clock source.

import _Volatile

// PMU_IMM_HP_CK_POWER_REG (PMU base 0x600B_0100 + 0xCC)
private let PMU_IMM_HP_CK_POWER_REG: UInt32 = 0x600B_01CC
private let PMU_TIE_HIGH_GLOBAL_BBPLL_ICG: UInt32 = 1 << 26
private let PMU_TIE_HIGH_XPD_BB_I2C: UInt32        = 1 << 28
private let PMU_TIE_HIGH_XPD_BBPLL: UInt32         = 1 << 30

// PCR registers (base 0x6009_6000)
private let PCR_SYSCLK_CONF_REG: UInt32  = 0x6009_6110
private let PCR_CPU_FREQ_CONF_REG: UInt32 = 0x6009_6118
private let PCR_AHB_FREQ_CONF_REG: UInt32 = 0x6009_611C
private let PCR_APB_FREQ_CONF_REG: UInt32 = 0x6009_6120

/// Switch CPU clock from XTAL to 160MHz PLL.
func configurePLL() {
    // 1. Power up BBPLL via PMU
    var pmuCk = regLoad(PMU_IMM_HP_CK_POWER_REG)
    pmuCk |= PMU_TIE_HIGH_XPD_BB_I2C
    pmuCk |= PMU_TIE_HIGH_XPD_BBPLL
    pmuCk |= PMU_TIE_HIGH_GLOBAL_BBPLL_ICG
    regStore(PMU_IMM_HP_CK_POWER_REG, pmuCk)

    // 2. Wait for PLL to stabilize (~10us at XTAL speed)
    for _ in 0..<200 {
        _ = regLoad(PMU_IMM_HP_CK_POWER_REG)
    }

    // 3. Set clock dividers BEFORE switching source
    //    CPU: 480MHz PLL / hardware-fixed-div3 / (div_num+1) = 160MHz
    //    cpu_hs_div_num=0, cpu_hs_120m_force=0
    regStore(PCR_CPU_FREQ_CONF_REG, 0)
    //    AHB: 160MHz / (1+1) = 80MHz
    regStore(PCR_AHB_FREQ_CONF_REG, 1)
    //    APB: same as AHB = 80MHz
    regStore(PCR_APB_FREQ_CONF_REG, 0)

    // 4. Switch SOC clock source to PLL (soc_clk_sel = 1)
    var sysclk = regLoad(PCR_SYSCLK_CONF_REG)
    sysclk = (sysclk & ~(0x3 << 16)) | (1 << 16)
    regStore(PCR_SYSCLK_CONF_REG, sysclk)
}
