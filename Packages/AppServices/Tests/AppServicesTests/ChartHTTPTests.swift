import ChartKit
import Foundation
import XCTest
@testable import AppServices

final class ChartHTTPTests: XCTestCase {
    let url = URL(string: "https://example.com/a.mbtiles")!
    let dest = URL(fileURLWithPath: "/tmp/a.partial")

    func testFreshDownloadHasNoRangeHeaders() {
        let headers = ChartHTTP.downloadHeaders(for: DownloadRequest(url: url, destination: dest, resumeOffset: 0, ifRange: "\"abc\""))
        XCTAssertEqual(headers, ["Accept-Encoding": "identity"])
    }

    func testResumeSendsRangeAndIfRange() {
        let headers = ChartHTTP.downloadHeaders(for: DownloadRequest(url: url, destination: dest, resumeOffset: 1234, ifRange: "\"abc\""))
        XCTAssertEqual(headers["Range"], "bytes=1234-")
        XCTAssertEqual(headers["If-Range"], "\"abc\"")
        let noValidator = ChartHTTP.downloadHeaders(for: DownloadRequest(url: url, destination: dest, resumeOffset: 10, ifRange: nil))
        XCTAssertEqual(noValidator["Range"], "bytes=10-")
        XCTAssertNil(noValidator["If-Range"])
        XCTAssertEqual(ChartHTTP.headHeaders()["Accept-Encoding"], "identity")
    }

    func testContentRangeParsing() {
        XCTAssertEqual(ContentRange.parse("bytes 100-199/1000"), ContentRange(start: 100, end: 199, total: 1000))
        XCTAssertEqual(ContentRange.parse("bytes 0-0/*"), ContentRange(start: 0, end: 0, total: nil))
        XCTAssertEqual(ContentRange.parse(" Bytes 5-9/10 "), ContentRange(start: 5, end: 9, total: 10))
        XCTAssertNil(ContentRange.parse("bytes */1000"))
        XCTAssertNil(ContentRange.parse("bytes 10-5/100"))
        XCTAssertNil(ContentRange.parse("bytes 0-99/99"))
        XCTAssertNil(ContentRange.parse("items 0-1/2"))
        XCTAssertNil(ContentRange.parse(""))
    }

    func testDecisions() {
        XCTAssertEqual(ChartHTTP.decide(statusCode: 200, resumeOffset: 0, headers: [:]), .write(.truncate))
        XCTAssertEqual(ChartHTTP.decide(statusCode: 200, resumeOffset: 500, headers: [:]), .write(.truncate),
                       "server ignored the range or the file changed: start over")
        XCTAssertEqual(ChartHTTP.decide(statusCode: 206, resumeOffset: 500, headers: ["content-range": "bytes 500-999/1000"]),
                       .write(.append))
        if case .fail(.other) = ChartHTTP.decide(statusCode: 206, resumeOffset: 400, headers: ["Content-Range": "bytes 500-999/1000"]) {
        } else {
            XCTFail("a range that does not start at the offset must be refused")
        }
        if case .fail(.other) = ChartHTTP.decide(statusCode: 206, resumeOffset: 500, headers: [:]) {} else {
            XCTFail("206 without Content-Range must be refused")
        }
        if case .fail(.other) = ChartHTTP.decide(statusCode: 206, resumeOffset: 0, headers: ["Content-Range": "bytes 0-9/10"]) {} else {
            XCTFail("206 to a non-range request must be refused")
        }
        XCTAssertEqual(ChartHTTP.decide(statusCode: 416, resumeOffset: 500, headers: [:]), .fail(.httpStatus(416)))
        XCTAssertEqual(ChartHTTP.decide(statusCode: 404, resumeOffset: 0, headers: [:]), .fail(.httpStatus(404)))
        XCTAssertEqual(ChartHTTP.decide(statusCode: 204, resumeOffset: 0, headers: [:]), .fail(.httpStatus(204)))
    }

    func testTotalLengthAndValidators() {
        let partial = ["Content-Range": "bytes 500-999/1000", "Content-Length": "500", "ETag": "\"v1\"",
                       "Last-Modified": "Tue, 28 May 2024 12:00:00 GMT"]
        XCTAssertEqual(ChartHTTP.totalLength(statusCode: 206, headers: partial), 1000)
        let v = ChartHTTP.validators(statusCode: 206, headers: partial)
        XCTAssertEqual(v.contentLength, 1000, "the part's Content-Length must not be reported as the file size")
        XCTAssertEqual(v.etag, "\"v1\"")
        XCTAssertEqual(v.lastModified, "Tue, 28 May 2024 12:00:00 GMT")

        let whole = ["content-length": "1000", "etag": "\"v1\""]
        XCTAssertEqual(ChartHTTP.totalLength(statusCode: 200, headers: whole), 1000)
        XCTAssertEqual(ChartHTTP.validators(statusCode: 200, headers: whole).contentLength, 1000)
        XCTAssertNil(ChartHTTP.totalLength(statusCode: 200, headers: [:]))
    }

    func testStringHeadersAndLookup() {
        let raw: [AnyHashable: Any] = ["ETag": "\"x\"", "Content-Length": 12 as NSNumber]
        let headers = ChartHTTP.stringHeaders(raw)
        XCTAssertEqual(headers["ETag"], "\"x\"")
        XCTAssertEqual(headers["Content-Length"], "12")
        XCTAssertEqual(ChartHTTP.header("etag", in: headers), "\"x\"")
        XCTAssertNil(ChartHTTP.header("Last-Modified", in: headers))
    }

    func testErrorMapping() {
        XCTAssertEqual(ChartHTTP.mapError(URLError(.networkConnectionLost)), .interrupted)
        XCTAssertEqual(ChartHTTP.mapError(URLError(.timedOut)), .interrupted)
        XCTAssertEqual(ChartHTTP.mapError(URLError(.notConnectedToInternet)), .interrupted)
        XCTAssertEqual(ChartHTTP.mapError(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(ChartHTTP.mapError(CancellationError()), .cancelled)
        XCTAssertEqual(ChartHTTP.mapError(TransportError.httpStatus(503)), .httpStatus(503))
        XCTAssertEqual(ChartHTTP.mapError(CocoaError(.fileWriteOutOfSpace)), .diskFull)
        XCTAssertEqual(ChartHTTP.mapError(POSIXError(.ENOSPC)), .diskFull)
        XCTAssertEqual(ChartHTTP.mapError(NSError(domain: NSPOSIXErrorDomain, code: 28)), .diskFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 28)])
        XCTAssertEqual(ChartHTTP.mapError(wrapped), .diskFull)
        if case .other = ChartHTTP.mapError(URLError(.badServerResponse)) {} else { XCTFail("expected .other") }
        XCTAssertEqual(ChartHTTP.mapDownloadError(URLError(.unknown), bodyStarted: true), .interrupted)
        XCTAssertEqual(ChartHTTP.mapDownloadError(URLError(.cancelled), bodyStarted: true), .cancelled)
        XCTAssertEqual(ChartHTTP.mapDownloadError(POSIXError(.ENOSPC), bodyStarted: true), .diskFull)
        XCTAssertEqual(ChartHTTP.mapDownloadError(TransportError.httpStatus(404), bodyStarted: false), .httpStatus(404))
        if case .other = ChartHTTP.mapDownloadError(URLError(.unknown), bodyStarted: false) {} else { XCTFail("expected .other") }
        if case .other = ChartHTTP.mapError(NSError(domain: "x", code: 1)) {} else { XCTFail("expected .other") }
    }
}
