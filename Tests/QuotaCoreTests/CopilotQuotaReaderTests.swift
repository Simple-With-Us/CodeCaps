import Foundation
import XCTest
@testable import QuotaCore

final class CopilotQuotaReaderTests: XCTestCase {
    private func read(_ json: String) async -> LocalQuotaResult {
        await CopilotQuotaReader(now: { Date(timeIntervalSince1970: 0) },
                                 runCopilot: { Data(json.utf8) }).read()
    }

    func testPlanOnlyDoesNotInventQuota() async {
        let result = await read(#"{"copilot_plan":"individual_pro","quota_reset_date":"2026-11-01"}"#)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 1)
        let window = result.windows[0]
        XCTAssertEqual(window.providerKey, "github-copilot")
        XCTAssertEqual(window.planName, "individual_pro")
        XCTAssertEqual(window.id, "local-mac:github-copilot:plan")
        XCTAssertEqual(window.resetAt, "2026-11-01T00:00:00Z")
        XCTAssertNil(window.remainingPercent)
        XCTAssertTrue(window.remainingUnknown)
        XCTAssertEqual(window.status, .unknown)
        XCTAssertFalse(window.isExhausted)
    }

    func testCountersAndPercentageKeepIndependentBuckets() async {
        let result = await read(#"{"copilot_plan":"business","quota_reset_date":"2026-11-01T00:00:00Z","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":60},"chat":{"entitlement":100,"remaining":0,"percent_remaining":0}}}"#)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].remainingPercent, 20)
        XCTAssertEqual(result.windows[0].absoluteRemaining, 60)
        XCTAssertEqual(result.windows[0].absoluteLimit, 300)
        XCTAssertEqual(result.windows[0].quotaUnit, "requests")
        XCTAssertEqual(result.windows[0].planName, "business")
        XCTAssertEqual(result.windows[1].status, .exhausted)
        XCTAssertTrue(result.windows[1].isExhausted)
        XCTAssertNotEqual(result.windows[0].id, result.windows[1].id)
    }

    func testUnlimitedDoesNotBecomeFullOrExhausted() async {
        let result = await read(#"{"copilot_plan":"individual","quota_snapshots":{"completions":{"unlimited":true,"entitlement":0,"remaining":0,"percent_remaining":100}}}"#)
        let window = result.windows[0]
        XCTAssertNil(window.remainingPercent)
        XCTAssertNil(window.absoluteLimit)
        XCTAssertNil(window.absoluteRemaining)
        XCTAssertTrue(window.remainingUnknown)
        XCTAssertFalse(window.isExhausted)
        XCTAssertTrue(window.label.contains("unlimited"))
    }

    func testMissingAndInvalidNumbersStayUnknown() async {
        for fixture in [
            #"{"quota_snapshots":{"chat":{}}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":0,"remaining":true,"percent_remaining":-1}}}"#
        ] {
            let result = await read(fixture)
            XCTAssertNil(result.windows.first?.remainingPercent)
            XCTAssertTrue(result.windows.first?.remainingUnknown == true)
            XCTAssertFalse(result.windows.first?.isExhausted == true)
        }
    }

    func testExplicitPercentWorksWithoutDenominatorAndClamps() async {
        let result = await read(#"{"quota_snapshots":{"premium_interactions":{"percent_remaining":125}}}"#)
        XCTAssertEqual(result.windows[0].remainingPercent, 100)
        XCTAssertNil(result.windows[0].absoluteLimit)
    }

    func testMalformedAndOversizedResponsesAreSafe() async {
        for fixture in ["not-json", "[]", "{}", String(repeating: "x", count: 262_145)] {
            let result = await read(fixture)
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertNotNil(result.issues["github-copilot"])
        }
    }

    func testAuthFailuresNeverEchoCredentialsOrUnderlyingErrors() async {
        struct AuthFailure: LocalizedError {
            var errorDescription: String? { "401 token ghp_fixture_do_not_export account@example.com" }
        }
        let result = await CopilotQuotaReader(runCopilot: { throw AuthFailure() }).read()
        XCTAssertTrue(result.windows.isEmpty)
        let message = result.issues["github-copilot"] ?? ""
        XCTAssertFalse(message.contains("ghp_fixture"))
        XCTAssertFalse(message.contains("account@example.com"))
        XCTAssertTrue(message.contains("sign-in"))
    }

    func testUnrelatedSensitiveResponseFieldsNeverReachWindows() async throws {
        let result = await read(#"{"copilot_plan":"business","token":"ghp_fixture_do_not_export","login":"private@example.com","quota_reset_date":"not-a-date"}"#)
        let encoded = String(decoding: try JSONEncoder().encode(result.windows), as: UTF8.self)
        XCTAssertFalse(encoded.contains("ghp_fixture"))
        XCTAssertFalse(encoded.contains("private@example.com"))
        XCTAssertNil(result.windows[0].resetAt)
    }

    func testCancellationIsSafe() async {
        let result = await CopilotQuotaReader(runCopilot: { throw CancellationError() }).read()
        XCTAssertEqual(result.issues["github-copilot"], "Copilot quota refresh was cancelled.")
    }
}
