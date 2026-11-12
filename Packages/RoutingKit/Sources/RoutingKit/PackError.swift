import Foundation

/// Why a routing pack could not be opened. Any of these means the file must not be used (spec A.4).
public enum PackError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The file could not be read from disk.
    case unreadable(String)
    /// The file is shorter than a header plus section table, or a structure runs past its end.
    case truncated(String)
    /// The first 8 bytes are not `GCRTPACK`.
    case badMagic
    /// A major version other than 1.
    case unsupportedVersion(major: Int, minor: Int)
    /// The header CRC-32 does not match bytes 0..251.
    case headerChecksumMismatch
    /// `file_size` in the header differs from the actual size.
    case fileSizeMismatch(header: Int, actual: Int)
    /// A header field is outside its allowed range.
    case invalidHeader(String)
    /// The section-table CRC-32 (format 1.1, header offset 108) does not match the table.
    case sectionTableChecksumMismatch
    /// The sections are not stored back to back in table order at 8-byte boundaries, a padding byte is not
    /// zero, or the file does not end at the padded end of the last section.
    case invalidLayout(String)
    /// A section's offset/length lies outside the file.
    case sectionOutOfBounds(tag: String)
    /// A section's stored bytes do not match its CRC-32.
    case sectionChecksumMismatch(tag: String)
    /// Two sections share a tag.
    case duplicateSection(tag: String)
    /// A required section is absent.
    case missingSection(tag: String)
    /// An encoding other than 0 (raw) or 1 (zlib).
    case unsupportedEncoding(tag: String, encoding: Int)
    /// The zlib stream is malformed.
    case inflateFailed(tag: String, reason: String)
    /// The inflated length differs from `raw_length` (or a raw section has raw_length != stored_length).
    case rawLengthMismatch(tag: String, expected: Int, actual: Int)
    /// A section decodes, but its content breaks the format (bad count, index out of range, ...).
    case malformedSection(tag: String, reason: String)

    public var description: String {
        switch self {
        case .unreadable(let s): return "routing pack unreadable: \(s)"
        case .truncated(let s): return "routing pack truncated: \(s)"
        case .badMagic: return "not a routing pack (bad magic)"
        case .unsupportedVersion(let major, let minor): return "unsupported routing pack version \(major).\(minor)"
        case .headerChecksumMismatch: return "routing pack header checksum mismatch"
        case .fileSizeMismatch(let h, let a): return "routing pack size mismatch: header says \(h) bytes, file has \(a)"
        case .invalidHeader(let s): return "invalid routing pack header: \(s)"
        case .sectionTableChecksumMismatch: return "routing pack section table checksum mismatch"
        case .invalidLayout(let s): return "invalid routing pack layout: \(s)"
        case .sectionOutOfBounds(let t): return "section \(t) lies outside the file"
        case .sectionChecksumMismatch(let t): return "section \(t) checksum mismatch"
        case .duplicateSection(let t): return "duplicate section \(t)"
        case .missingSection(let t): return "missing section \(t)"
        case .unsupportedEncoding(let t, let e): return "section \(t) has unsupported encoding \(e)"
        case .inflateFailed(let t, let r): return "section \(t) failed to inflate: \(r)"
        case .rawLengthMismatch(let t, let e, let a): return "section \(t) inflated to \(a) bytes, expected \(e)"
        case .malformedSection(let t, let r): return "section \(t) is malformed: \(r)"
        }
    }
}
