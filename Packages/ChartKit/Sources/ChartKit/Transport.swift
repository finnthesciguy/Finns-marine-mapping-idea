import Foundation

/// A GET to perform, possibly resuming a partial file.
public struct DownloadRequest: Sendable, Equatable {
    public var url: URL
    /// File the body is written into. When `resumeOffset > 0` it already holds that many bytes.
    public var destination: URL
    /// 0 for a fresh download; otherwise send `Range: bytes=<resumeOffset>-`.
    public var resumeOffset: Int64
    /// When resuming, send `If-Range: <value>` so a changed server file comes back whole (200).
    public var ifRange: String?

    public init(url: URL, destination: URL, resumeOffset: Int64, ifRange: String?) {
        self.url = url
        self.destination = destination
        self.resumeOffset = resumeOffset
        self.ifRange = ifRange
    }
}

public struct DownloadResponse: Sendable, Equatable {
    /// 200: the transport wrote the whole body to `destination` starting at byte 0 (truncating it).
    /// 206: the transport appended the body to `destination` after `resumeOffset` bytes.
    public var statusCode: Int
    /// Validators from the response headers (ETag / Last-Modified / Content-Length).
    public var validators: RemoteValidators
    /// Total size of the remote file, from `Content-Range` (206) or `Content-Length` (200), if known.
    public var totalLength: Int64?

    public init(statusCode: Int, validators: RemoteValidators, totalLength: Int64?) {
        self.statusCode = statusCode
        self.validators = validators
        self.totalLength = totalLength
    }
}

/// Errors a transport should throw. Anything else is reported as a generic transport failure,
/// except `CancellationError` and out-of-space file errors, which ChartKit recognises.
public enum TransportError: Error, Equatable, Sendable {
    /// The connection dropped part-way. `destination` holds whatever arrived; ChartKit will resume.
    case interrupted
    /// A non-2xx response (e.g. 404, 416, 503).
    case httpStatus(Int)
    /// Writing the body failed because the disk is full.
    case diskFull
    case cancelled
    case other(String)
}

/// The network seam. ChartKit owns all the logic (resume bookkeeping, validator checks, hashing,
/// integrity checks, the swap); a transport only moves bytes. The iOS app supplies a
/// background-URLSession implementation; tests supply a fake.
///
/// Contract for `download`:
/// * `resumeOffset == 0`: GET the URL, truncate `destination`, write the body from byte 0, return 200.
/// * `resumeOffset > 0`: GET with `Range: bytes=<offset>-` and `If-Range: <ifRange>` when given.
///   On 206, append to `destination`; on 200 (server ignored the range, or the file changed),
///   truncate and write from 0. Report the status you got.
/// * `progress` receives the number of bytes now in `destination` (resumed bytes included).
/// * On a dropped connection throw `TransportError.interrupted`, leaving the bytes written so far.
public protocol ChartTransport: Sendable {
    func head(_ url: URL) async throws -> RemoteValidators
    func download(_ request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadResponse
}

/// Free-space precheck hook.
public protocol DiskSpaceProvider: Sendable {
    /// Bytes available for new files on the volume holding `directory`.
    func availableBytes(for directory: URL) throws -> Int64
}

/// Asks the file system. On Apple platforms this uses the "important usage" capacity, which counts
/// purgeable space iOS would free for a user-initiated download.
public struct FileSystemDiskSpace: DiskSpaceProvider {
    public init() {}

    public func availableBytes(for directory: URL) throws -> Int64 {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let v = values.volumeAvailableCapacityForImportantUsage { return v }
        #endif
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let n = attrs[.systemFreeSize] as? NSNumber { return n.int64Value }
        if let n = attrs[.systemFreeSize] as? Int64 { return n }
        if let n = attrs[.systemFreeSize] as? Int { return Int64(n) }
        return Int64.max
    }
}
