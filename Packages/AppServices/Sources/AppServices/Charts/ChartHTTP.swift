import ChartKit
import Foundation

/// A parsed `Content-Range: bytes <start>-<end>/<total>` header (`total` is nil for `*`).
public struct ContentRange: Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    public var total: Int64?

    public init(start: Int64, end: Int64, total: Int64?) {
        self.start = start
        self.end = end
        self.total = total
    }

    /// Parses `bytes 100-199/1000` or `bytes 100-199/*`. Unsatisfied ranges (`bytes */1000`) and anything
    /// malformed return nil.
    public static func parse(_ value: String) -> ContentRange? {
        let trimmed: String = value.trimmingCharacters(in: .whitespaces)
        let lower: String = trimmed.lowercased()
        guard lower.hasPrefix("bytes") else { return nil }
        let rest: String = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        let halves: [Substring] = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let rangePart: [Substring] = halves[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangePart.count == 2,
              let start = Int64(rangePart[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(rangePart[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start else { return nil }
        let totalText: String = halves[1].trimmingCharacters(in: .whitespaces)
        var total: Int64? = nil
        if totalText != "*" {
            guard let t = Int64(totalText), t > end else { return nil }
            total = t
        }
        return ContentRange(start: start, end: end, total: total)
    }
}

/// The HTTP rules of ChartKit's `ChartTransport` contract, as pure functions (tested on Linux) so the
/// URLSession adapters stay thin.
public enum ChartHTTP {
    /// How the body of a download response is written to the destination file.
    public enum WriteMode: Sendable, Equatable {
        /// Truncate the destination and write the body from byte 0 (status 200).
        case truncate
        /// Keep the first `resumeOffset` bytes and append the body (status 206).
        case append
    }

    public enum ResponseDecision: Sendable, Equatable {
        case write(WriteMode)
        case fail(TransportError)
    }

    /// Headers for the validator HEAD. `identity` keeps proxies from compressing a binary package,
    /// which would make `Content-Length` and byte ranges refer to the compressed form.
    public static func headHeaders() -> [String: String] {
        ["Accept-Encoding": "identity"]
    }

    /// Headers for a GET: `Range` and `If-Range` when resuming (contract: `resumeOffset > 0`).
    public static func downloadHeaders(for request: DownloadRequest) -> [String: String] {
        var headers: [String: String] = ["Accept-Encoding": "identity"]
        if request.resumeOffset > 0 {
            headers["Range"] = "bytes=\(request.resumeOffset)-"
            if let ifRange = request.ifRange, !ifRange.isEmpty {
                headers["If-Range"] = ifRange
            }
        }
        return headers
    }

    /// `HTTPURLResponse.allHeaderFields` as plain strings.
    public static func stringHeaders(_ raw: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in raw {
            let name: String = String(describing: key)
            if let text = value as? String {
                result[name] = text
            } else {
                result[name] = String(describing: value)
            }
        }
        return result
    }

    /// Case-insensitive header lookup.
    public static func header(_ name: String, in headers: [String: String]) -> String? {
        let wanted: String = name.lowercased()
        for (key, value) in headers where key.lowercased() == wanted {
            return value
        }
        return nil
    }

    /// What to do with a response to a download GET, decided before any body byte is written.
    ///
    /// * 200: the whole file follows; truncate (also when we asked for a range: the server ignored it or
    ///   `If-Range` did not match because the file changed).
    /// * 206: only valid when resuming, and only if the range starts exactly at `resumeOffset`;
    ///   anything else would corrupt the partial file.
    /// * Anything else: `TransportError.httpStatus`.
    public static func decide(statusCode: Int, resumeOffset: Int64, headers: [String: String]) -> ResponseDecision {
        switch statusCode {
        case 200:
            return .write(.truncate)
        case 206:
            guard resumeOffset > 0 else {
                return .fail(.other("unexpected 206 Partial Content for a request without Range"))
            }
            guard let raw = header("Content-Range", in: headers), let range = ContentRange.parse(raw) else {
                return .fail(.other("206 Partial Content without a usable Content-Range header"))
            }
            guard range.start == resumeOffset else {
                return .fail(.other("206 Partial Content starts at byte \(range.start), expected \(resumeOffset)"))
            }
            return .write(.append)
        default:
            return .fail(.httpStatus(statusCode))
        }
    }

    /// Total size of the remote file: from `Content-Range` on a 206, else `Content-Length` on a 200.
    public static func totalLength(statusCode: Int, headers: [String: String]) -> Int64? {
        if statusCode == 206 {
            if let raw = header("Content-Range", in: headers), let range = ContentRange.parse(raw) {
                return range.total
            }
            return nil
        }
        if let raw = header("Content-Length", in: headers), let length = Int64(raw.trimmingCharacters(in: .whitespaces)),
           length >= 0 {
            return length
        }
        return nil
    }

    /// Validators reported to ChartKit for a download response. On a 206 the `Content-Length` header is
    /// the length of the part, so the full length from `Content-Range` is reported instead.
    public static func validators(statusCode: Int, headers: [String: String]) -> RemoteValidators {
        var validators = RemoteValidators(headers: headers)
        if statusCode == 206 {
            validators.contentLength = totalLength(statusCode: statusCode, headers: headers)
        }
        return validators
    }

    /// URL error codes that mean "the connection went away"; ChartKit resumes after these.
    public static let interruptionCodes: Set<Int> = [
        URLError.Code.networkConnectionLost.rawValue,
        URLError.Code.timedOut.rawValue,
        URLError.Code.notConnectedToInternet.rawValue,
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
        URLError.Code.dataNotAllowed.rawValue,
        URLError.Code.internationalRoamingOff.rawValue,
        URLError.Code.callIsActive.rawValue,
        URLError.Code.cannotLoadFromNetwork.rawValue,
        URLError.Code.backgroundSessionWasDisconnected.rawValue,
    ]

    private static let enospc: Int = 28

    /// True for "disk full" errors from file writes (Cocoa or POSIX flavour).
    public static func isDiskFull(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return true }
        if let posix = error as? POSIXError, posix.code.rawValue == Int32(enospc) { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == enospc { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            if underlying.domain == NSPOSIXErrorDomain && underlying.code == enospc { return true }
        }
        return false
    }

    /// Maps an error that ended a download. Once a 200/206 body has started arriving, any network
    /// failure other than cancellation or a full disk is a dropped connection: the bytes already written
    /// belong to the server's file, so ChartKit should resume (`.interrupted`). This also covers errors
    /// that some URLSession implementations report without a specific code (libcurl's "transfer closed
    /// with N bytes remaining" arrives as URL error -1 on Linux).
    public static func mapDownloadError(_ error: any Error, bodyStarted: Bool) -> TransportError {
        let mapped: TransportError = mapError(error)
        if bodyStarted, case .other = mapped { return .interrupted }
        return mapped
    }

    /// Maps any error from URLSession or file writes onto ChartKit's `TransportError`.
    public static func mapError(_ error: any Error) -> TransportError {
        if let transport = error as? TransportError { return transport }
        if error is CancellationError { return .cancelled }
        if isDiskFull(error) { return .diskFull }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            if interruptionCodes.contains(urlError.code.rawValue) { return .interrupted }
            return .other("URL error \(urlError.code.rawValue): \(urlError.localizedDescription)")
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == URLError.Code.cancelled.rawValue { return .cancelled }
            if interruptionCodes.contains(ns.code) { return .interrupted }
            return .other("URL error \(ns.code): \(ns.localizedDescription)")
        }
        return .other(String(describing: error))
    }
}
