import Foundation

/// Bounds-checked little-endian reads from a byte buffer. Every read that would run past the end
/// returns nil instead of trapping, so a truncated or corrupt pack becomes a typed error.
struct ByteView {
    let base: UnsafeBufferPointer<UInt8>

    init(_ base: UnsafeBufferPointer<UInt8>) { self.base = base }

    var count: Int { base.count }

    @inline(__always) func has(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= base.count && length <= base.count - offset
    }

    @inline(__always) func u8(_ o: Int) -> UInt8? { has(o, 1) ? base[o] : nil }

    @inline(__always) func u16(_ o: Int) -> UInt16? {
        guard has(o, 2) else { return nil }
        return UInt16(base[o]) | UInt16(base[o + 1]) << 8
    }

    @inline(__always) func u32(_ o: Int) -> UInt32? {
        guard has(o, 4) else { return nil }
        return UInt32(base[o]) | UInt32(base[o + 1]) << 8 | UInt32(base[o + 2]) << 16 | UInt32(base[o + 3]) << 24
    }

    @inline(__always) func u64(_ o: Int) -> UInt64? {
        guard let lo = u32(o), let hi = u32(o + 4) else { return nil }
        return UInt64(lo) | UInt64(hi) << 32
    }

    @inline(__always) func i16(_ o: Int) -> Int16? { u16(o).map { Int16(bitPattern: $0) } }
    @inline(__always) func i32(_ o: Int) -> Int32? { u32(o).map { Int32(bitPattern: $0) } }
}

/// Sequential LEB128 reader (spec A.1) over a byte buffer.
struct VarintCursor {
    let base: UnsafeBufferPointer<UInt8>
    var position: Int

    init(_ base: UnsafeBufferPointer<UInt8>, position: Int = 0) {
        self.base = base
        self.position = position
    }

    var atEnd: Bool { position >= base.count }

    /// Next uvarint, or nil if the data ends inside it, it is longer than 10 bytes, or it overflows 64 bits.
    @inline(__always) mutating func next() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = position
        let n = base.count
        while i < n {
            let byte = base[i]
            i += 1
            if shift == 63 && byte > 1 { return nil }  // the 10th byte may only carry bit 63
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                position = i
                return result
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

/// Zigzag decode (spec A.1): `n = (u >> 1) ^ -(u & 1)`.
@inline(__always) func unzigzag(_ u: UInt64) -> Int64 {
    Int64(bitPattern: (u >> 1) ^ (0 &- (u & 1)))
}

/// Floor division for integers (spec A.1: every division in the format rounds toward minus infinity).
@inline(__always) func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q
}
