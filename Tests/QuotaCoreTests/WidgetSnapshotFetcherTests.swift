import Foundation
import XCTest
@testable import QuotaCore

final class WidgetSnapshotFetcherTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchRequiresHTTPSAndUsesBearerOnlyForConfiguredRequest() async throws {
        let expected = Data("{\"windows\":[]}".utf8)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.timeoutInterval, 10)
            return .init(statusCode: 200, data: expected)
        }

        let data = try await WidgetSnapshotFetcher.fetch(
            endpoint: "https://quotas.example.test/api/snapshot",
            bearerToken: "test-token",
            configuration: stubConfiguration()
        )
        XCTAssertEqual(data, expected)

        do {
            _ = try await WidgetSnapshotFetcher.fetch(
                endpoint: "http://quotas.example.test/api/snapshot",
                bearerToken: "test-token",
                configuration: stubConfiguration()
            )
            XCTFail("HTTP endpoints must be rejected before sending the bearer token")
        } catch {
            XCTAssertEqual(error as? WidgetSnapshotFetcher.FetchError, .invalidHTTPSURL)
        }
    }

    func testFetchRejectsCrossOriginRedirectWithoutSendingSecondRequest() async throws {
        var requests = 0
        StubURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "quotas.example.test")
            return .redirect(statusCode: 302, to: "https://other.example.test/stolen")
        }

        do {
            _ = try await WidgetSnapshotFetcher.fetch(
                endpoint: "https://quotas.example.test/api/snapshot",
                bearerToken: "test-token",
                configuration: stubConfiguration()
            )
            XCTFail("Cross-origin redirects must be rejected")
        } catch {
            XCTAssertEqual(requests, 1)
        }
    }

    func testFetchRejectsHTTPSDowngradeRedirect() async throws {
        var requests = 0
        StubURLProtocol.handler = { _ in
            requests += 1
            return .redirect(statusCode: 307, to: "http://quotas.example.test/insecure")
        }

        do {
            _ = try await WidgetSnapshotFetcher.fetch(
                endpoint: "https://quotas.example.test/api/snapshot",
                bearerToken: "test-token",
                configuration: stubConfiguration()
            )
            XCTFail("HTTPS downgrade redirects must be rejected")
        } catch {
            XCTAssertEqual(requests, 1)
        }
    }

    func testFetchRejectsOversizedBodyWithoutContentLength() async throws {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, data: Data(repeating: 65, count: 1_024 * 1_024 + 1))
        }
        do {
            _ = try await WidgetSnapshotFetcher.fetch(
                endpoint: "https://quotas.example.test/api/snapshot",
                bearerToken: "",
                configuration: stubConfiguration()
            )
            XCTFail("An unbounded response must not be cached by the widget")
        } catch {
            XCTAssertEqual(error as? WidgetSnapshotFetcher.FetchError, .responseTooLarge)
        }
    }

    func testFetchRejectsAuthenticationFailureInsteadOfCachingItsBody() async throws {
        StubURLProtocol.handler = { _ in
            .init(statusCode: 401, data: Data("unauthorized".utf8))
        }
        do {
            _ = try await WidgetSnapshotFetcher.fetch(
                endpoint: "https://quotas.example.test/api/snapshot",
                bearerToken: "invalid-token",
                configuration: stubConfiguration()
            )
            XCTFail("An error response must not replace the last valid widget snapshot")
        } catch {
            XCTAssertEqual(error as? WidgetSnapshotFetcher.FetchError, .unacceptableStatus(401))
        }
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

private final class StubURLProtocol: URLProtocol {
    struct Response {
        let statusCode: Int
        let data: Data
        let redirectLocation: URL?

        init(statusCode: Int, data: Data) {
            self.statusCode = statusCode
            self.data = data
            self.redirectLocation = nil
        }

        init(statusCode: Int, redirectLocation: URL) {
            self.statusCode = statusCode
            self.data = Data()
            self.redirectLocation = redirectLocation
        }

        static func redirect(statusCode: Int, to location: String) -> Response {
            Response(statusCode: statusCode, redirectLocation: URL(string: location)!)
        }
    }

    static var handler: ((URLRequest) -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stubResponse = handler(request)
        guard let response = stubResponse.makeResponse(url: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let location = stubResponse.redirectLocation {
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: location),
                redirectResponse: response
            )
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stubResponse.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension StubURLProtocol.Response {
    func makeResponse(url: URL) -> HTTPURLResponse? {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
    }
}
