import Foundation
import XCTest
@testable import QuotaCore

final class OpenCodeGoQuotaReaderTests: XCTestCase {
    private func read(
        _ json: String, status: Int = 200, token: String? = "go-key"
    ) async -> LocalQuotaResult {
        await OpenCodeGoQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { token },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: OpenCodeGoQuotaReader.usageURL,
                    statusCode: status, httpVersion: nil, headerFields: nil
                )!
                return (Data(json.utf8), response)
            }
        ).read()
    }

    func testUsagePercentsAreInvertedToRemaining() async {
        let result = await read(#"{"usage":{"rolling":{"status":"ok","percent":25,"resetsAt":"2026-11-25T10:00:00Z"},"weekly":{"status":"ok","percent":50,"resetsAt":"2026-11-30T00:00:00Z"},"monthly":{"status":"ok","percent":90,"resetsAt":"2026-12-25T00:00:00Z"}}}"#)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.map(\.label), ["5 hours", "Weekly", "Monthly"])
        XCTAssertEqual(result.windows.map(\.remainingPercent), [75, 50, 10])
        XCTAssertEqual(result.windows.map(\.window), ["5h", "weekly", "monthly"])
        XCTAssertEqual(result.windows.first?.providerKey, "opencode-go")
        XCTAssertEqual(result.windows.first?.providerLabel, "OpenCode Go")
        XCTAssertEqual(result.windows.first?.resetAt, "2026-11-25T10:00:00Z")
        XCTAssertEqual(result.windows.last?.status, .nearCap)
    }

    func testRateLimitedWindowIsExhausted() async {
        let result = await read(#"{"usage":{"rolling":{"status":"rate-limited","percent":100,"resetsAt":"2026-11-25T10:00:00Z"}}}"#)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows.first?.remainingPercent, 0)
        XCTAssertTrue(result.windows.first?.isExhausted == true)
        XCTAssertEqual(result.windows.first?.status, .exhausted)
    }

    func testNoLocalKeyIsAbsentWithoutIssue() async {
        let result = await read("{}", token: nil)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testRejectedKeyAndMissingSubscriptionWording() async {
        let rejected = await read("{}", status: 401)
        XCTAssertEqual(rejected.issues["opencode-go"], "OpenCode Go rejected the saved key; sign in again in OpenCode.")
        let unsubscribed = await read("{}", status: 403)
        XCTAssertEqual(unsubscribed.issues["opencode-go"], "OpenCode Go reports no active Go subscription for this key.")
    }

    func testUnparseablePayloadReportsNoReadableQuota() async {
        let result = await read(#"{"usage":{"rolling":{"status":"ok"}}}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["opencode-go"], "OpenCode Go returned no readable quota.")
    }

    func testAuthFileGoKeyExtraction() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-go-tests-\(UUID().uuidString)")
        let authDir = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let auth = #"{"anthropic":{"type":"oauth"},"opencode-go":{"type":"api","key":"go-secret"}}"#
        try Data(auth.utf8).write(to: authDir.appendingPathComponent("auth.json"))
        XCTAssertEqual(OpenCodeGoQuotaReader.readGoKey(home: home, environment: [:]), "go-secret")
    }

    func testAuthFileOAuthOnlyEntryIsAbsent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-go-tests-\(UUID().uuidString)")
        let authDir = home.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"opencode-go":{"type":"oauth","access":"x"}}"#.utf8)
            .write(to: authDir.appendingPathComponent("auth.json"))
        XCTAssertNil(OpenCodeGoQuotaReader.readGoKey(home: home, environment: [:]))
    }
}
