import Foundation
import Testing
@testable import ChartKit

@Suite struct SHA256Tests {
    // FIPS 180-4 / NIST CAVP vectors.
    @Test(arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
        ("The quick brown fox jumps over the lazy dog",
         "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"),
    ])
    func knownVectors(input: String, expected: String) {
        #expect(StreamingSHA256.hash(Data(input.utf8)) == expected)
    }

    @Test func oneMillionAs() {
        var h = StreamingSHA256()
        let chunk = [UInt8](repeating: 0x61, count: 1000)
        for _ in 0..<1000 { h.update(chunk) }
        #expect(h.finalizeHex() == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func chunkingDoesNotChangeTheDigest() {
        var bytes = [UInt8]()
        for i in 0..<1000 { bytes.append(UInt8(truncatingIfNeeded: i &* 31 &+ 7)) }
        let whole = StreamingSHA256.hash(Data(bytes))
        for split in [1, 3, 55, 56, 63, 64, 65, 127, 128, 999] {
            var h = StreamingSHA256()
            var i = 0
            while i < bytes.count {
                let end = min(bytes.count, i + split)
                h.update(Array(bytes[i..<end]))
                i = end
            }
            #expect(h.finalizeHex() == whole, "split \(split)")
        }
    }

    @Test func paddingBoundaries() {
        // Lengths around the 55/56/64-byte padding edges, checked against values from `sha256sum`.
        let expected: [Int: String] = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
        ]
        for (n, digest) in expected {
            #expect(StreamingSHA256.hash(Data(repeating: 0x61, count: n)) == digest, "length \(n)")
        }
    }

    @Test func hashesFilesInChunks() throws {
        let dir = try TempDir()
        defer { dir.cleanup() }
        let url = dir.file("blob")
        var data = Data()
        for i in 0..<300_000 { data.append(UInt8(truncatingIfNeeded: i)) }
        try data.write(to: url)
        var seen: [Int64] = []
        let digest = try StreamingSHA256.hash(fileAt: url, chunkSize: 65_536) { seen.append($0) }
        #expect(digest == StreamingSHA256.hash(data))
        #expect(seen.last == 300_000)
        #expect(seen.count == 5)
    }

    @Test func hexValidation() {
        #expect(StreamingSHA256.isValidHexDigest(String(repeating: "a", count: 64)))
        #expect(StreamingSHA256.isValidHexDigest(String(repeating: "F", count: 64)))
        #expect(!StreamingSHA256.isValidHexDigest(String(repeating: "g", count: 64)))
        #expect(!StreamingSHA256.isValidHexDigest("abc"))
    }
}
