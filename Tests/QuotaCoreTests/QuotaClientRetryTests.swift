import Foundation
import XCTest
@testable import QuotaCore

final class QuotaClientRetryTests: XCTestCase {
  private let successBody = """
  {"generatedAt":"2023-11-14T22:10:00Z","windows":[],"skipModelTypes":[]}
  """.data(using: .utf8)!

  override func setUp() {
    super.setUp()
    StubURLProtocol.seenURLs = []
    StubURLProtocol.handler = nil
    StubURLProtocol.failURLError = nil
    QuotaClientRetryTiming.sleep = { _ in }
    IdempotentGETRetryFilter.endFetch(endpoint: URL(string: "https://usage.jays.services/api/quota-windows")!)
  }

  func testRetriable503sRetryUntilSuccess() async throws {
    var attempts = 0
    StubURLProtocol.handler = { _ in
      attempts += 1
      if attempts < 3 {
        return StubURLProtocol.reply(status: 503, body: Data())
      }
      return StubURLProtocol.reply(status: 200, body: self.successBody)
    }
    let client = try QuotaClient(
      endpoint: URL(string: "https://usage.jays.services/api/quota-windows")!,
      token: "secret",
      urlProtocolClasses: [StubURLProtocol.self]
    )
    let response = try await client.fetch()
    XCTAssertEqual(response.windows.count, 0)
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(StubURLProtocol.seenURLs.count, 3)
  }

  func testExhausted503ThrowsAfterThreeAttempts() async throws {
    var attempts = 0
    StubURLProtocol.handler = { _ in
      attempts += 1
      return StubURLProtocol.reply(status: 503, body: Data())
    }
    let endpoint = URL(string: "https://usage.jays.services/api/quota-windows")!
    let client = try QuotaClient(
      endpoint: endpoint,
      token: "secret",
      urlProtocolClasses: [StubURLProtocol.self]
    )
    var exhausted = false
    QuotaClientExhaustedTransientRead.onExhausted = { url, error in
      XCTAssertEqual(url, endpoint)
      XCTAssertEqual(error, .httpStatus(503))
      exhausted = true
    }
    defer { QuotaClientExhaustedTransientRead.onExhausted = nil }

    do {
      _ = try await client.fetch()
      XCTFail("expected exhausted 503")
    } catch let error as QuotaClientError {
      XCTAssertEqual(error, .httpStatus(503))
    }
    XCTAssertEqual(attempts, 3)
    XCTAssertTrue(exhausted)
  }

  func testNonRetriable500DoesNotRetry() async throws {
    var attempts = 0
    StubURLProtocol.handler = { _ in
      attempts += 1
      return StubURLProtocol.reply(status: 500, body: Data())
    }
    let client = try QuotaClient(
      endpoint: URL(string: "https://usage.jays.services/api/quota-windows")!,
      token: "secret",
      urlProtocolClasses: [StubURLProtocol.self]
    )
    do {
      _ = try await client.fetch()
      XCTFail("expected 500")
    } catch let error as QuotaClientError {
      XCTAssertEqual(error, .httpStatus(500))
    }
    XCTAssertEqual(attempts, 1)
  }

  func testRetryAfterIsCappedAtFiveSeconds() {
    XCTAssertEqual(
      IdempotentGETRetryFilter.backoffDelay(attemptIndex: 1, retryAfter: "30"),
      5
    )
    XCTAssertEqual(
      IdempotentGETRetryFilter.backoffDelay(attemptIndex: 1, retryAfter: "2"),
      2
    )
    XCTAssertEqual(
      IdempotentGETRetryFilter.backoffDelay(attemptIndex: 2, retryAfter: nil),
      0.7,
      accuracy: 0.001
    )
  }

  func testTransientPullFailureClassification() {
    XCTAssertTrue(QuotaClientError.isTransientPullFailure(QuotaClientError.httpStatus(503)))
    XCTAssertTrue(QuotaClientError.isTransientPullFailure(QuotaClientError.transport))
    XCTAssertFalse(QuotaClientError.isTransientPullFailure(QuotaClientError.unauthorized))
    XCTAssertFalse(QuotaClientError.isTransientPullFailure(QuotaClientError.httpStatus(500)))
  }

  func testPreservesLastGoodOnlyForRetriableHTTPStatuses() {
    XCTAssertTrue(IdempotentGETRetryFilter.preservesLastGoodFleetOnPullFailure(
      QuotaClientError.httpStatus(503)))
    XCTAssertFalse(IdempotentGETRetryFilter.preservesLastGoodFleetOnPullFailure(
      QuotaClientError.transport))
    XCTAssertFalse(IdempotentGETRetryFilter.preservesLastGoodFleetOnPullFailure(
      QuotaClientError.timedOut))
  }

  func testWrappedTransportErrorsRetryUntilSuccess() async throws {
    var attempts = 0
    StubURLProtocol.failURLError = { _ in
      attempts += 1
      if attempts < 3 {
        return URLError(.networkConnectionLost)
      }
      return nil
    }
    StubURLProtocol.handler = { _ in
      StubURLProtocol.reply(status: 200, body: self.successBody)
    }
    let client = try QuotaClient(
      endpoint: URL(string: "https://usage.jays.services/api/quota-windows")!,
      token: "secret",
      urlProtocolClasses: [StubURLProtocol.self]
    )
    _ = try await client.fetch()
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(StubURLProtocol.seenURLs.count, 3)
  }

  func testWrappedTransportErrorsExhaustAfterThreeAttempts() async throws {
    var attempts = 0
    StubURLProtocol.failURLError = { _ in
      attempts += 1
      return URLError(.networkConnectionLost)
    }
    let client = try QuotaClient(
      endpoint: URL(string: "https://usage.jays.services/api/quota-windows")!,
      token: "secret",
      urlProtocolClasses: [StubURLProtocol.self]
    )
    do {
      _ = try await client.fetch()
      XCTFail("expected transport failure")
    } catch let error as QuotaClientError {
      XCTAssertEqual(error, .transport)
    }
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(StubURLProtocol.seenURLs.count, 3)
  }

  func testSentrySuppressesAutomatic503WhileFetchInFlight() {
    let url = "https://usage.jays.services/api/quota-windows"
    let endpoint = URL(string: url)!
    IdempotentGETRetryFilter.beginFetch(endpoint: endpoint)
    defer { IdempotentGETRetryFilter.endFetch(endpoint: endpoint) }

    XCTAssertTrue(IdempotentGETRetryFilter.shouldSuppressAutomaticFailedRequest(
      url: url,
      httpMethod: "GET",
      exceptionTypes: ["HTTPClientError"],
      exceptionValues: ["HTTP Client Error with status code: 503"]
    ))
    XCTAssertFalse(IdempotentGETRetryFilter.shouldSuppressAutomaticFailedRequest(
      url: url,
      httpMethod: "GET",
      exceptionTypes: ["HTTPClientError"],
      exceptionValues: ["HTTP Client Error with status code: 500"]
    ))
    XCTAssertFalse(IdempotentGETRetryFilter.shouldSuppressAutomaticFailedRequest(
      url: "https://api2.cursor.sh/x",
      httpMethod: "GET",
      exceptionTypes: ["HTTPClientError"],
      exceptionValues: ["HTTP Client Error with status code: 503"]
    ))
  }
}

// File-private so each test file in this target keeps its own URL stub.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Reply {
    let status: Int
    let headers: [String: String]
    let body: Data
  }

  static var handler: ((URLRequest) -> Reply)?
  static var failURLError: ((URLRequest) -> URLError?)?
  static var seenURLs: [String] = []

  static func reply(status: Int, headers: [String: String] = [:], body: Data) -> Reply {
    Reply(status: status, headers: headers, body: body)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else { return }
    Self.seenURLs.append(url.path)
    if let urlError = Self.failURLError?(request) {
      client?.urlProtocol(self, didFailWithError: urlError)
      return
    }
    let reply = Self.handler?(request) ?? Self.reply(status: 500, body: Data())
    let response = HTTPURLResponse(
      url: url,
      statusCode: reply.status,
      httpVersion: "HTTP/1.1",
      headerFields: reply.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
