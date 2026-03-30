# Task 1: Toolchain Setup

## Required Tools

| Tool | Version | Source |
|------|---------|--------|
| Swift 6.3 | `TOOLCHAINS=org.swift.630202603201a` | Swift.org toolchain |
| ld.lld | Bundled with Swift toolchain | `xcrun --toolchain org.swift.630202603201a -f ld.lld` |

## Environment Variables

```bash
export TOOLCHAINS=org.swift.630202603201a
export PATH="$(dirname $(xcrun --toolchain org.swift.630202603201a -f ld.lld)):$PATH"
```

## Build Command

```bash
swift build --triple riscv32-none-none-eabi --toolset toolset.json
```

## Verification

```bash
# Verify Swift RISC-V target support
TOOLCHAINS=org.swift.630202603201a swiftc -target riscv32-none-none-eabi -print-target-info

# Verify ld.lld
xcrun --toolchain org.swift.630202603201a -f ld.lld
```
