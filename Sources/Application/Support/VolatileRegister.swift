import _Volatile

@inline(__always)
func regLoad(_ address: UInt32) -> UInt32 {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
}

@inline(__always)
func regStore(_ address: UInt32, _ value: UInt32) {
    VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
}
