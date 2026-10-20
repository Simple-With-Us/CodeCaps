import XCTest
@testable import QuotaCore

final class UsageAlertPublisherTests: XCTestCase {
    func testAlertEndpointPreservesOriginAndDropsQueryCredentials() {
        let input = URL(string: "https://example.com:8443/api/ingest?token=secret#fragment")!
        XCTAssertEqual(UsageAlertPublisher.endpoint(for: input)?.absoluteString,
                       "https://example.com:8443/api/codecaps/push/alerts")
    }

    func testRejectsInsecureAndEmbeddedCredentials() {
        XCTAssertNil(UsageAlertPublisher.endpoint(for: URL(string: "http://example.com/api/ingest")!))
        XCTAssertNil(UsageAlertPublisher.endpoint(for: URL(string: "https://name:password@example.com/api/ingest")!))
        XCTAssertNil(UsageAlertPublisher.endpoint(for: URL(string: "file:///tmp/snapshot")!))
    }
}
