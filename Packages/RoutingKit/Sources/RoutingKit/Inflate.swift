import Foundation

/// A malformed zlib/DEFLATE stream.
public struct InflateError: Error, Hashable, Sendable, CustomStringConvertible {
    public let reason: String
    init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// Pure-Swift zlib (RFC 1950) / DEFLATE (RFC 1951) decoder.
///
/// RoutingKit inflates pack sections itself instead of linking libz, so the package has no system
/// dependency on Linux (CI's Swift container installs only libsqlite3-dev) and behaves identically
/// on every platform. The decoder is strict: the stream must end exactly at the end of the input,
/// produce exactly `expectedLength` bytes and match its Adler-32 trailer. Every input error is a
/// thrown ``InflateError``; nothing reads or writes out of bounds.
public enum Zlib {
    /// Decompresses a complete zlib stream that must inflate to exactly `expectedLength` bytes.
    public static func decompress(_ input: [UInt8], expectedLength: Int) throws(InflateError) -> [UInt8] {
        try input.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) throws(InflateError) -> [UInt8] in
            try decompress(p, expectedLength: expectedLength)
        }
    }

    /// Decompresses a complete zlib stream that must inflate to exactly `expectedLength` bytes.
    public static func decompress(_ input: UnsafeBufferPointer<UInt8>, expectedLength: Int) throws(InflateError) -> [UInt8] {
        guard expectedLength >= 0 else { throw InflateError("negative output length") }
        guard input.count >= 6 else { throw InflateError("stream too short") }
        let cmf = input[0], flg = input[1]
        guard cmf & 0x0F == 8 else { throw InflateError("compression method is not DEFLATE") }
        guard cmf >> 4 <= 7 else { throw InflateError("window size too large") }
        guard (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else { throw InflateError("bad zlib header check bits") }
        guard flg & 0x20 == 0 else { throw InflateError("preset dictionary not supported") }

        var output = [UInt8](repeating: 0, count: expectedLength)
        var failure: InflateError?
        var produced = 0
        var consumed = 0
        output.withUnsafeMutableBufferPointer { (out: inout UnsafeMutableBufferPointer<UInt8>) in
            var inflater = Inflater(input: input, start: 2, output: out)
            do throws(InflateError) {
                try inflater.run()
                produced = inflater.outPos
                consumed = inflater.byteAlignedPosition()
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        guard produced == expectedLength else {
            throw InflateError("inflated \(produced) bytes, expected \(expectedLength)")
        }
        guard consumed + 4 == input.count else {
            throw InflateError(consumed + 4 > input.count ? "missing Adler-32 trailer" : "trailing bytes after stream")
        }
        let stored = UInt32(input[consumed]) << 24 | UInt32(input[consumed + 1]) << 16
            | UInt32(input[consumed + 2]) << 8 | UInt32(input[consumed + 3])
        let actual = output.withUnsafeBufferPointer { Adler32.checksum($0) }
        guard stored == actual else { throw InflateError("Adler-32 mismatch") }
        return output
    }
}

// MARK: - Huffman tables

private let fastBits = 10
private let fastSize = 1 << fastBits

/// Canonical Huffman decoding table: a 10-bit direct lookup plus the canonical counts/symbols for longer codes.
private struct Huffman {
    /// (symbol << 4) | length for codes of length <= fastBits, indexed by the next bits of input; 0 = slow path.
    var fast = [UInt16](repeating: 0, count: fastSize)
    var counts = [UInt16](repeating: 0, count: 16)
    var symbols: [UInt16] = []

    /// Builds the table. `allowIncomplete` accepts an incomplete code only when it has a single
    /// length-1 code (as zlib does); an empty code is accepted and fails on first use.
    init(lengths: ArraySlice<UInt8>, allowIncomplete: Bool) throws(InflateError) {
        for l in lengths { counts[Int(l)] += 1 }
        counts[0] = 0
        var left = 1
        var maxLen = 0
        for len in 1...15 {
            left <<= 1
            left -= Int(counts[len])
            if left < 0 { throw InflateError("over-subscribed Huffman code") }
            if counts[len] > 0 { maxLen = len }
        }
        if left > 0 && maxLen > 0 {
            if !(allowIncomplete && maxLen == 1) { throw InflateError("incomplete Huffman code") }
        }
        var offs = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offs[len + 1] = offs[len] + Int(counts[len]) }
        symbols = [UInt16](repeating: 0, count: lengths.count)
        // First code of each length (RFC 1951 3.2.2); counts[0] is zero.
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for bits in 1...15 {
            code = (code + Int(counts[bits - 1])) << 1
            nextCode[bits] = code
        }
        var sym = 0
        for l in lengths {
            let len = Int(l)
            if len != 0 {
                symbols[offs[len]] = UInt16(sym)
                offs[len] += 1
                let c = nextCode[len]
                nextCode[len] += 1
                if len <= fastBits {
                    var rev = 0
                    var v = c
                    for _ in 0..<len {
                        rev = (rev << 1) | (v & 1)
                        v >>= 1
                    }
                    let entry = UInt16(sym << 4 | len)
                    var i = rev
                    while i < fastSize {
                        fast[i] = entry
                        i += 1 << len
                    }
                }
            }
            sym += 1
        }
    }
}

private let lengthBase: [UInt16] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                                    131, 163, 195, 227, 258]
private let lengthExtra: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
private let distBase: [UInt16] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                  2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
private let distExtra: [UInt8] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
private let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

private let fixedTables: (Huffman, Huffman) = {
    var lit = [UInt8](repeating: 8, count: 288)
    for i in 144..<256 { lit[i] = 9 }
    for i in 256..<280 { lit[i] = 7 }
    let dist = [UInt8](repeating: 5, count: 32)
    // Both codes are complete, so construction cannot fail.
    let l = try! Huffman(lengths: lit[...], allowIncomplete: false)
    let d = try! Huffman(lengths: dist[...], allowIncomplete: false)
    return (l, d)
}()

// MARK: - Decoder

private struct Inflater {
    let input: UnsafeBufferPointer<UInt8>
    var pos: Int
    var bitBuf: UInt64 = 0
    var bitCnt: Int = 0
    let out: UnsafeMutableBufferPointer<UInt8>
    var outPos = 0

    init(input: UnsafeBufferPointer<UInt8>, start: Int, output: UnsafeMutableBufferPointer<UInt8>) {
        self.input = input
        self.pos = start
        self.out = output
    }

    /// Input position of the first unconsumed whole byte (after discarding partial-byte bits).
    func byteAlignedPosition() -> Int { pos - bitCnt / 8 }

    @inline(__always) mutating func refill() {
        while bitCnt <= 56 && pos < input.count {
            bitBuf |= UInt64(input[pos]) << UInt64(bitCnt)
            pos += 1
            bitCnt += 8
        }
    }

    @inline(__always) mutating func bits(_ n: Int) throws(InflateError) -> Int {
        if n == 0 { return 0 }
        if bitCnt < n {
            refill()
            if bitCnt < n { throw InflateError("unexpected end of stream") }
        }
        let v = Int(bitBuf & ((1 << UInt64(n)) - 1))
        bitBuf >>= UInt64(n)
        bitCnt -= n
        return v
    }

    @inline(__always) mutating func decode(_ h: Huffman) throws(InflateError) -> Int {
        if bitCnt < 15 { refill() }
        let e = Int(h.fast[Int(bitBuf & UInt64(fastSize - 1))])
        if e != 0 {
            let len = e & 15
            if len > bitCnt { throw InflateError("unexpected end of stream") }
            bitBuf >>= UInt64(len)
            bitCnt -= len
            return e >> 4
        }
        // Slow path: canonical decode bit by bit (codes longer than fastBits, or invalid codes).
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= try bits(1)
            let count = Int(h.counts[len])
            if code - count < first { return Int(h.symbols[index + (code - first)]) }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw InflateError("invalid Huffman code")
    }

    mutating func run() throws(InflateError) {
        var final = false
        while !final {
            final = try bits(1) == 1
            let type = try bits(2)
            switch type {
            case 0: try stored()
            case 1: try codes(fixedTables.0, fixedTables.1)
            case 2:
                let (l, d) = try dynamicTables()
                try codes(l, d)
            default: throw InflateError("invalid block type")
            }
        }
    }

    mutating func stored() throws(InflateError) {
        // Discard the partial byte, then give back whole bytes still in the bit buffer.
        bitBuf = 0
        pos -= bitCnt / 8
        bitCnt = 0
        guard pos + 4 <= input.count else { throw InflateError("unexpected end of stream") }
        let len = Int(input[pos]) | Int(input[pos + 1]) << 8
        let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
        pos += 4
        guard len == (~nlen & 0xFFFF) else { throw InflateError("stored block length check failed") }
        guard pos + len <= input.count else { throw InflateError("unexpected end of stream") }
        guard outPos + len <= out.count else { throw InflateError("output exceeds expected length") }
        for i in 0..<len { out[outPos + i] = input[pos + i] }
        pos += len
        outPos += len
    }

    mutating func dynamicTables() throws(InflateError) -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw InflateError("bad dynamic block counts") }
        var clens = [UInt8](repeating: 0, count: 19)
        for i in 0..<ncode { clens[codeLengthOrder[i]] = UInt8(try bits(3)) }
        let clh = try Huffman(lengths: clens[...], allowIncomplete: false)
        var lengths = [UInt8](repeating: 0, count: nlen + ndist)
        var index = 0
        while index < nlen + ndist {
            let sym = try decode(clh)
            if sym < 16 {
                lengths[index] = UInt8(sym)
                index += 1
            } else {
                var value: UInt8 = 0
                var rep: Int
                if sym == 16 {
                    guard index > 0 else { throw InflateError("repeat with no previous length") }
                    value = lengths[index - 1]
                    rep = 3 + (try bits(2))
                } else if sym == 17 {
                    rep = 3 + (try bits(3))
                } else {
                    rep = 11 + (try bits(7))
                }
                guard index + rep <= nlen + ndist else { throw InflateError("too many code lengths") }
                for _ in 0..<rep {
                    lengths[index] = value
                    index += 1
                }
            }
        }
        guard lengths[256] != 0 else { throw InflateError("no end-of-block code") }
        let l = try Huffman(lengths: lengths[0..<nlen], allowIncomplete: true)
        let d = try Huffman(lengths: lengths[nlen..<(nlen + ndist)], allowIncomplete: true)
        return (l, d)
    }

    mutating func codes(_ lit: Huffman, _ dist: Huffman) throws(InflateError) {
        while true {
            let sym = try decode(lit)
            if sym < 256 {
                guard outPos < out.count else { throw InflateError("output exceeds expected length") }
                out[outPos] = UInt8(sym)
                outPos += 1
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw InflateError("invalid length symbol") }
                let length = Int(lengthBase[li]) + (try bits(Int(lengthExtra[li])))
                let ds = try decode(dist)
                guard ds < 30 else { throw InflateError("invalid distance symbol") }
                let distance = Int(distBase[ds]) + (try bits(Int(distExtra[ds])))
                guard distance <= outPos else { throw InflateError("distance too far back") }
                guard outPos + length <= out.count else { throw InflateError("output exceeds expected length") }
                var from = outPos - distance
                for _ in 0..<length {
                    out[outPos] = out[from]
                    outPos += 1
                    from += 1
                }
            }
        }
    }
}
