import Foundation

/// CRC-32 as in zlib's `crc32()` (IEEE 802.3, reflected polynomial 0xEDB88320), spec A.1.
/// Slicing-by-8 so that checking a whole pack stays cheap even in debug builds.
public enum CRC32 {
    private static let tables: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            t[i] = c
        }
        for i in 0..<256 {
            var c = t[i]
            for k in 1..<8 {
                c = t[Int(c & 0xFF)] ^ (c >> 8)
                t[k * 256 + i] = c
            }
        }
        return t
    }()

    /// CRC-32 of `bytes`, continuing from `crc` (pass 0 to start).
    public static func checksum(_ bytes: UnsafeBufferPointer<UInt8>, continuing crc: UInt32 = 0) -> UInt32 {
        var c = ~crc
        let n = bytes.count
        guard n > 0, let p = bytes.baseAddress else { return crc }
        tables.withUnsafeBufferPointer { tb in
            let t = tb.baseAddress!
            var i = 0
            while i + 8 <= n {
                let lo = c ^ (UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24)
                let hi = UInt32(p[i + 4]) | UInt32(p[i + 5]) << 8 | UInt32(p[i + 6]) << 16 | UInt32(p[i + 7]) << 24
                c = t[7 * 256 + Int(lo & 0xFF)] ^ t[6 * 256 + Int((lo >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((lo >> 16) & 0xFF)] ^ t[4 * 256 + Int(lo >> 24)]
                    ^ t[3 * 256 + Int(hi & 0xFF)] ^ t[2 * 256 + Int((hi >> 8) & 0xFF)]
                    ^ t[1 * 256 + Int((hi >> 16) & 0xFF)] ^ t[Int(hi >> 24)]
                i += 8
            }
            while i < n {
                c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8)
                i += 1
            }
        }
        return ~c
    }

    /// CRC-32 of a byte array.
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { checksum($0) }
    }
}

/// Adler-32 (RFC 1950), used to verify the zlib trailer.
enum Adler32 {
    static func checksum(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var i = 0
        let n = bytes.count
        while i < n {
            let end = min(i + 5552, n)  // NMAX: largest run before 32-bit overflow
            while i < end {
                a &+= UInt32(bytes[i])
                b &+= a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }
}
