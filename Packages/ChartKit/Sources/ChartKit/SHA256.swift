import Foundation

/// A small, dependency-free streaming SHA-256 (FIPS 180-4). CryptoKit is Apple-only, so ChartKit
/// carries its own. Feed it any number of chunks, then call `finalize()` once.
public struct StreamingSHA256: Sendable {
    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
        (0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19)
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var bufferCount = 0
    private var totalLength: UInt64 = 0
    private var finalized = false

    public init() {}

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(bufferPointer: $0) }
    }

    public mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update(bufferPointer: $0) }
    }

    public mutating func update(bufferPointer input: UnsafeRawBufferPointer) {
        precondition(!finalized, "StreamingSHA256 used after finalize()")
        guard input.count > 0 else { return }
        totalLength &+= UInt64(input.count)
        var offset = 0
        if bufferCount > 0 {
            let take = min(64 - bufferCount, input.count)
            for i in 0..<take { buffer[bufferCount + i] = input[i] }
            bufferCount += take
            offset = take
            if bufferCount == 64 {
                buffer.withUnsafeBytes { compress($0) }
                bufferCount = 0
            }
        }
        while input.count - offset >= 64 {
            compress(UnsafeRawBufferPointer(rebasing: input[offset..<(offset + 64)]))
            offset += 64
        }
        let rest = input.count - offset
        if rest > 0 {
            for i in 0..<rest { buffer[i] = input[offset + i] }
            bufferCount = rest
        }
    }

    /// Returns the 32-byte digest. The hasher cannot be used afterwards.
    public mutating func finalize() -> [UInt8] {
        precondition(!finalized, "StreamingSHA256 finalized twice")
        let bitLength = totalLength &* 8
        var pad: [UInt8] = [0x80]
        let padZeros = (bufferCount + 1 <= 56) ? 56 - (bufferCount + 1) : 120 - (bufferCount + 1)
        pad += [UInt8](repeating: 0, count: padZeros)
        for i in (0..<8).reversed() { pad.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        let saved = totalLength
        update(pad)
        totalLength = saved
        finalized = true
        let s = [state.0, state.1, state.2, state.3, state.4, state.5, state.6, state.7]
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for word in s {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    public mutating func finalizeHex() -> String { Self.hex(finalize()) }

    private mutating func compress(_ block: UnsafeRawBufferPointer) {
        // A stack-allocated message schedule: no heap traffic per 64-byte block.
        let newState = withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w -> (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) in
            for i in 0..<16 {
                let b = i * 4
                w[i] = UInt32(block[b]) << 24 | UInt32(block[b + 1]) << 16 | UInt32(block[b + 2]) << 8 | UInt32(block[b + 3])
            }
            for i in 16..<64 {
                let s0 = w[i - 15].rotr(7) ^ w[i - 15].rotr(18) ^ (w[i - 15] >> 3)
                let s1 = w[i - 2].rotr(17) ^ w[i - 2].rotr(19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, h) = state
            Self.k.withUnsafeBufferPointer { k in
                for i in 0..<64 {
                    let s1 = e.rotr(6) ^ e.rotr(11) ^ e.rotr(25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                    let s0 = a.rotr(2) ^ a.rotr(13) ^ a.rotr(22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = s0 &+ maj
                    h = g; g = f; f = e; e = d &+ t1
                    d = c; c = b; b = a; a = t1 &+ t2
                }
            }
            return (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d,
                    state.4 &+ e, state.5 &+ f, state.6 &+ g, state.7 &+ h)
        }
        state = newState
    }

    // MARK: Conveniences

    public static func hash(_ data: Data) -> String {
        var h = StreamingSHA256()
        h.update(data)
        return h.finalizeHex()
    }

    /// Hashes a file in fixed-size chunks so a 600 MB package never sits in memory.
    /// `progress` receives the bytes hashed so far.
    public static func hash(fileAt url: URL, chunkSize: Int = 1 << 20,
                            progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var h = StreamingSHA256()
        var done: Int64 = 0
        while true {
            let chunk = try autoreleasepoolCompat { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            h.update(chunk)
            done += Int64(chunk.count)
            progress?(done)
        }
        return h.finalizeHex()
    }

    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// True for a 64-character hex string (either case).
    public static func isValidHexDigest(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }
}

private extension UInt32 {
    @inline(__always) func rotr(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}

@inline(__always)
private func autoreleasepoolCompat<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}
