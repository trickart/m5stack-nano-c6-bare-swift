// MARK: - ChaCha20 Block Cipher

@inline(__always)
private func rotl(_ v: UInt32, _ n: Int) -> UInt32 {
    (v << n) | (v >> (32 - n))
}

@inline(__always)
private func quarterRound(
    _ s: UnsafeMutablePointer<UInt32>,
    _ a: Int, _ b: Int, _ c: Int, _ d: Int
) {
    s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
    s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
    s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
    s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
}

/// Compute one ChaCha20 block (20 rounds).
/// - Parameters:
///   - input: 16 x UInt32 words (constants + key + counter + nonce)
///   - output: 16 x UInt32 output block
func chacha20Block(
    _ input: UnsafePointer<UInt32>,
    _ output: UnsafeMutablePointer<UInt32>
) {
    // Copy input to working state
    for i in 0..<16 {
        output[i] = input[i]
    }

    // 10 double rounds = 20 rounds
    for _ in 0..<10 {
        // Column rounds
        quarterRound(output, 0, 4,  8, 12)
        quarterRound(output, 1, 5,  9, 13)
        quarterRound(output, 2, 6, 10, 14)
        quarterRound(output, 3, 7, 11, 15)
        // Diagonal rounds
        quarterRound(output, 0, 5, 10, 15)
        quarterRound(output, 1, 6, 11, 12)
        quarterRound(output, 2, 7,  8, 13)
        quarterRound(output, 3, 4,  9, 14)
    }

    // Add input state to output
    for i in 0..<16 {
        output[i] = output[i] &+ input[i]
    }
}
