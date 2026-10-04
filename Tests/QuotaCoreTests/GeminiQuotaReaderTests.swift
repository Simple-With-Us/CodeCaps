import Foundation
import XCTest
@testable import QuotaCore

final class GeminiQuotaReaderTests: XCTestCase {
    func testReadsGeminiQuotaWithoutExposingCredentials() async throws {
        let home = try makeHome(credentials: #"{"access_token":"gemini-secret","expiry_date":4102444800000}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = GeminiQuotaReader(homeDirectory: home, fetchJSON: { request in
            XCTAssertEqual(request.url?.host, "cloudcode-pa.googleapis.com")
            XCTAssertEqual(request.url?.path, "/v1internal:retrieveUserQuota")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gemini-secret")
            return Self.response(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":0.42,"resetTime":"2026-09-14T00:00:00Z"}]}"#)
        })

        let result = await reader.read()
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.providerKey, "gemini-cli")
        XCTAssertEqual(result.windows.first?.modelId, "gemini-pro")
        XCTAssertEqual(result.windows.first?.remainingPercent, 42)
        XCTAssertEqual(result.windows.first?.resetAt, "2026-09-14T00:00:00Z")
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testUnauthorizedResponseIsSanitized() async throws {
        let home = try makeHome(credentials: #"{"access_token":"hidden"}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = GeminiQuotaReader(homeDirectory: home, fetchJSON: { _ in Self.response(#"{"account":"hidden"}"#, status: 401) })

        let result = await reader.read()
        XCTAssertEqual(result.issues["gemini-cli"], "Gemini CLI needs you to sign in again.")
        XCTAssertFalse(result.issues.values.joined(separator: " ").contains("hidden"))
    }

    func testExpiredCredentialsDoNotMakeARequest() async throws {
        let home = try makeHome(credentials: #"{"access_token":"expired","expiry_date":1}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = GeminiQuotaReader(homeDirectory: home, now: { Date(timeIntervalSince1970: 100) }, fetchJSON: { _ in
            XCTFail("Expired credentials must not be used")
            return Self.response("{}")
        })

        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["gemini-cli"], "Gemini CLI needs you to sign in again.")
    }

    func testUnreadableQuotaBucketRemainsUnknownAndSanitized() async throws {
        let home = try makeHome(credentials: #"{"access_token":"token"}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let reader = GeminiQuotaReader(homeDirectory: home, fetchJSON: { _ in
            Self.response(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":1.7}]}"#)
        })

        let result = await reader.read()
        XCTAssertEqual(result.windows.first?.remainingPercent, nil)
        XCTAssertEqual(result.windows.first?.remainingUnknown, true)
        XCTAssertTrue(result.issues.isEmpty)
    }

    private func makeHome(credentials: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try Data(credentials.utf8).write(to: home.appendingPathComponent(".gemini/oauth_creds.json"))
        return home
    }

    private static func response(_ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://fixture.invalid")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
