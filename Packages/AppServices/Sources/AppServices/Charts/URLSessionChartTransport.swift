import ChartKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ChartKit's `ChartTransport` over a foreground `URLSession`.
///
/// * `head` sends a HEAD and returns the validators (ETag, Last-Modified, Content-Length, Accept-Ranges).
/// * `download` streams the body straight into `DownloadRequest.destination` through a data task, so a
///   600 MB package never needs a second copy on disk. Resuming sends `Range` and `If-Range`; a 206 is
///   appended after the existing bytes, a 200 truncates and starts again (see `ChartHTTP.decide`).
///   Progress reports the bytes now in the destination, resumed bytes included. A dropped connection
///   throws `TransportError.interrupted` and leaves the bytes written so far; a full disk throws
///   `TransportError.diskFull`; Swift task cancellation cancels the request and throws `.cancelled`.
///
/// Each download uses its own `URLSession` (invalidated when it finishes), so the transport keeps no
/// shared mutable state. Downloads stop when iOS suspends the app; the partial file stays and ChartKit
/// resumes it next time. A background-session variant (see App/README.md) would replace the data task
/// with a download task in a background `URLSessionConfiguration` and append the delivered temporary
/// file to the destination, reusing `ChartHTTP` for every header and status decision.
public final class URLSessionChartTransport: ChartTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { URLSessionChartTransport.defaultConfiguration() }) {
        self.makeConfiguration = configuration
    }

    /// No caching (packages are hundreds of MB), long resource timeout, cellular allowed (the user
    /// confirmed the download size first).
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.allowsCellularAccess = true
        return configuration
    }

    public func head(_ url: URL) async throws -> RemoteValidators {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in ChartHTTP.headHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let response: URLResponse
        do {
            let result: (Data, URLResponse) = try await session.data(for: request)
            response = result.1
        } catch {
            throw ChartHTTP.mapError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.other("HEAD \(url.absoluteString): not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TransportError.httpStatus(http.statusCode)
        }
        let headers: [String: String] = ChartHTTP.stringHeaders(http.allHeaderFields)
        var validators = RemoteValidators(headers: headers)
        if validators.contentLength == nil && http.expectedContentLength > 0 {
            validators.contentLength = http.expectedContentLength
        }
        return validators
    }

    public func download(_ request: DownloadRequest,
                         progress: @escaping @Sendable (Int64) -> Void) async throws -> DownloadResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in ChartHTTP.downloadHeaders(for: request) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let job = StreamingDownloadJob(request: request, progress: progress)
        let session = URLSession(configuration: makeConfiguration(), delegate: job, delegateQueue: job.queue)
        return try await job.run(session: session, urlRequest: urlRequest)
    }
}

/// One streamed GET. All delegate callbacks arrive on `queue` (serial); the lock also covers the
/// cancellation handler, which runs on whatever thread cancels the Swift task.
final class StreamingDownloadJob: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let queue: OperationQueue

    private let request: DownloadRequest
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<DownloadResponse, any Error>?
    private var task: URLSessionDataTask?
    private var cancelledByCaller = false
    private var decided = false
    private var statusCode = 0
    private var headers: [String: String] = [:]
    private var handle: FileHandle?
    private var bytesInFile: Int64 = 0
    private var pendingError: (any Error)?
    /// True once a 200/206 was accepted and the destination opened for writing.
    private var bodyStarted = false

    init(request: DownloadRequest, progress: @escaping @Sendable (Int64) -> Void) {
        self.request = request
        self.progress = progress
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "URLSessionChartTransport.download"
        self.queue = queue
        super.init()
    }

    func run(session: URLSession, urlRequest: URLRequest) async throws -> DownloadResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DownloadResponse, any Error>) in
                lock.lock()
                self.continuation = continuation
                let dataTask: URLSessionDataTask = session.dataTask(with: urlRequest)
                self.task = dataTask
                let cancelNow: Bool = cancelledByCaller
                lock.unlock()
                dataTask.resume()
                if cancelNow {
                    dataTask.cancel()
                }
            }
        } onCancel: {
            self.cancelFromCaller()
        }
    }

    private func cancelFromCaller() {
        lock.lock()
        cancelledByCaller = true
        let current: URLSessionDataTask? = task
        lock.unlock()
        current?.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var report: Int64? = nil
        lock.lock()
        if pendingError == nil {
            if !decided {
                decided = true
                openDestination(for: dataTask.response)
            }
            if pendingError == nil, let handle {
                do {
                    try handle.write(contentsOf: data)
                    bytesInFile += Int64(data.count)
                    report = bytesInFile
                } catch {
                    pendingError = error
                }
            }
        }
        let failed: Bool = pendingError != nil
        lock.unlock()
        if failed {
            dataTask.cancel()
        } else if let report {
            progress(report)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        if error == nil && pendingError == nil && !decided {
            // A response with an empty body: still apply the status rules (e.g. truncate on 200).
            decided = true
            openDestination(for: task.response)
        }
        closeHandle()
        let result: Result<DownloadResponse, any Error>
        if let pendingError {
            result = .failure(ChartHTTP.mapError(pendingError))
        } else if let error {
            if cancelledByCaller {
                result = .failure(TransportError.cancelled)
            } else {
                result = .failure(ChartHTTP.mapDownloadError(error, bodyStarted: bodyStarted))
            }
        } else {
            let response = DownloadResponse(statusCode: statusCode,
                                            validators: ChartHTTP.validators(statusCode: statusCode, headers: headers),
                                            totalLength: ChartHTTP.totalLength(statusCode: statusCode, headers: headers))
            result = .success(response)
        }
        let waiting: CheckedContinuation<DownloadResponse, any Error>? = continuation
        continuation = nil
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        waiting?.resume(with: result)
    }

    // MARK: File handling (called with the lock held)

    private func openDestination(for response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else {
            pendingError = TransportError.other("GET \(request.url.absoluteString): not an HTTP response")
            return
        }
        statusCode = http.statusCode
        headers = ChartHTTP.stringHeaders(http.allHeaderFields)
        let decision: ChartHTTP.ResponseDecision = ChartHTTP.decide(statusCode: statusCode,
                                                                    resumeOffset: request.resumeOffset,
                                                                    headers: headers)
        switch decision {
        case .fail(let failure):
            pendingError = failure
        case .write(let mode):
            do {
                try open(mode: mode)
                bodyStarted = true
            } catch {
                pendingError = error
            }
        }
    }

    private func open(mode: ChartHTTP.WriteMode) throws {
        let fileManager = FileManager.default
        let path: String = request.destination.path
        switch mode {
        case .truncate:
            if !fileManager.createFile(atPath: path, contents: nil) {
                throw TransportError.other("cannot create \(path)")
            }
            let fileHandle = try FileHandle(forWritingTo: request.destination)
            try fileHandle.truncate(atOffset: 0)
            handle = fileHandle
            bytesInFile = 0
        case .append:
            guard fileManager.fileExists(atPath: path) else {
                throw TransportError.other("resume requested but \(path) does not exist")
            }
            let fileHandle = try FileHandle(forWritingTo: request.destination)
            // The contract says the destination holds exactly `resumeOffset` bytes. Fewer would leave a
            // hole; more are cut back so the appended range lines up.
            let existing: UInt64 = try fileHandle.seekToEnd()
            if existing < UInt64(request.resumeOffset) {
                try? fileHandle.close()
                throw TransportError.other("resume from byte \(request.resumeOffset) but \(path) holds \(existing) bytes")
            }
            try fileHandle.truncate(atOffset: UInt64(request.resumeOffset))
            try fileHandle.seek(toOffset: UInt64(request.resumeOffset))
            handle = fileHandle
            bytesInFile = request.resumeOffset
        }
    }

    private func closeHandle() {
        guard let handle else { return }
        try? handle.synchronize()
        try? handle.close()
        self.handle = nil
    }
}
