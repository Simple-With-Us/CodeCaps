import Foundation
import XCTest
@testable import QuotaCore

/// The one shared fetch behind the local readers' production transports.
/// These lock its contract through a stub URLProtocol: bodies pass through
/// untouched, the byte cap rejects, non-2xx statuses reach the caller (the
/// readers own their reauth wording), redirects are never followed, and a
/// cancelled task stays a `CancellationError`.
final class BoundedHTTPFetchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testSmallBodyPassesThrough() async throws {
        let url = URL(string: "https://fetch.test/small")!
        StubURLProtocol.register(url, statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await BoundedHTTPFetch.data(for: request, timeout: 5, maxBytes: 1024, protocolClasses: [StubURLProtocol.self])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(StubURLProtocol.requestedURLs(), [url.absoluteString])
    }

    func testBodyBeyondTheCapIsRejected() async {
        let url = URL(string: "https://fetch.test/large")!
        StubURLProtocol.register(url, statusCode: 200, body: Data(repeating: 65, count: 2048))
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            _ = try await BoundedHTTPFetch.data(for: request, timeout: 5, maxBytes: 1024, protocolClasses: [StubURLProtocol.self])
            XCTFail("A body beyond the cap was accepted")
        } catch let failure as BoundedHTTPFetch.Failure {
            XCTAssertEqual(failure, .tooLarge)
        } catch {
            XCTFail("Expected BoundedHTTPFetch.Failure.tooLarge, got \(error)")
        }
    }

    func testNonSuccessStatusReachesTheCaller() async throws {
        let url = URL(string: "https://fetch.test/denied")!
        StubURLProtocol.register(url, statusCode: 401, body: Data("denied".utf8))
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await BoundedHTTPFetch.data(for: request, timeout: 5, maxBytes: 1024, protocolClasses: [StubURLProtocol.self])
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(data, Data("denied".utf8))
    }

    func testRedirectIsNeverFollowed() async {
        let start = URL(string: "https://fetch.test/start")!
        let target = URL(string: "https://fetch.test/target")!
        StubURLProtocol.registerRedirect(start, target)
        StubURLProtocol.register(target, statusCode: 200, body: Data("followed".utf8))
        var request = URLRequest(url: start)
        request.timeoutInterval = 5
        do {
            _ = try await BoundedHTTPFetch.data(for: request, timeout: 5, maxBytes: 1024, protocolClasses: [StubURLProtocol.self])
            XCTFail("A redirect was followed or accepted")
        } catch let failure as BoundedHTTPFetch.Failure {
            XCTAssertEqual(failure, .transport)
        } catch {
            XCTFail("Expected BoundedHTTPFetch.Failure.transport, got \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestedURLs(), [start.absoluteString])
    }

    func testCallerTimeoutIsCappedNotRaised() async throws {
        let url = URL(string: "https://fetch.test/tight")!
        StubURLProtocol.register(url, statusCode: 200, body: Data("ok".utf8))
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        _ = try await BoundedHTTPFetch.data(for: request, timeout: 15, maxBytes: 1024, protocolClasses: [StubURLProtocol.self])
        XCTAssertEqual(StubURLProtocol.requestedTimeoutIntervals(), [2], "A tighter per-request timeout must survive the fetch budget")
    }

    func testUnsetRequestTakesTheFetchBudget() async throws {
        let url = URL(string: "https://fetch.test/budget")!
        StubURLProtocol.register(url, statusCode: 200, body: Data("ok".utf8))
        let request = URLRequest(url: url)
        _ = try await BoundedHTTPFetch.data(for: request, timeout: 15, maxBytes: 1024, protocolClasses: [StubURLProtocol.self])
        XCTAssertEqual(StubURLProtocol.requestedTimeoutIntervals(), [15], "An unset request (system default 60 s) takes the fetch budget")
    }

    func testCancellationSurfacesAsCancellationError() async {
        let url = URL(string: "https://fetch.test/hangs")!
        StubURLProtocol.registerHanging(url)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = Task { try await BoundedHTTPFetch.data(for: request, timeout: 2, maxBytes: 1024, protocolClasses: [StubURLProtocol.self]) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled fetch succeeded")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }
}

/// A configurable stub for every fetch the helper makes. It records each
/// requested URL so the redirect test can prove the target was never touched.
private final class StubURLProtocol: URLProtocol {
    private enum Stub {
        case body(statusCode: Int, body: Data)
        case redirect(target: URL)
        case hangs
    }

    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]
    private static var requests: [String] = []
    private static var timeouts: [TimeInterval] = []

    static func register(_ url: URL, statusCode: Int, body: Data) {
        lock.lock(); stubs[url.absoluteString] = .body(statusCode: statusCode, body: body); lock.unlock()
    }

    static func registerRedirect(_ url: URL, _ target: URL) {
        lock.lock(); stubs[url.absoluteString] = .redirect(target: target); lock.unlock()
    }

    static func registerHanging(_ url: URL) {
        lock.lock(); stubs[url.absoluteString] = .hangs; lock.unlock()
    }

    static func requestedURLs() -> [String] {
        lock.lock(); defer { lock.unlock() }; return requests
    }

    static func requestedTimeoutIntervals() -> [TimeInterval] {
        lock.lock(); defer { lock.unlock() }; return timeouts
    }

    static func reset() {
        lock.lock(); stubs = [:]; requests = []; timeouts = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.requests.append(url.absoluteString)
        Self.timeouts.append(request.timeoutInterval)
        let stub = Self.stubs[url.absoluteString]
        Self.lock.unlock()
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch stub {
        case let .body(statusCode, body):
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .hangs:
            break
        }
    }

    override func stopLoading() {}
}
