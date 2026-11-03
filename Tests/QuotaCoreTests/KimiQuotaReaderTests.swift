import Foundation
import XCTest
@testable import QuotaCore

final class KimiQuotaReaderTests: XCTestCase {
    private func read(
        _ json: String,
        status: Int = 200,
        token: String? = "token"
    ) async -> LocalQuotaResult {
        await KimiQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { token },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.kimi.com/coding/v1/usages")!,
                    statusCode: status, httpVersion: nil, headerFields: nil
                )!
                return (Data(json.utf8), response)
            }
        ).read()
    }

    func testSummaryRowBecomesWeeklyWindow() async {
        let result = await read(#"{"usage":{"limit":100,"used":25,"reset_at":"2026-11-08T00:00:00Z"}}"#)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 1)
        let window = result.windows[0]
        XCTAssertEqual(window.providerKey, "kimi")
        XCTAssertEqual(window.providerLabel, "Kimi")
        XCTAssertEqual(window.label, "Weekly limit")
        XCTAssertEqual(window.remainingPercent, 75)
        XCTAssertEqual(window.absoluteRemaining, 75)
        XCTAssertEqual(window.absoluteLimit, 100)
        XCTAssertEqual(window.resetAt, "2026-11-08T00:00:00Z")
        XCTAssertEqual(window.status, .available)
        XCTAssertFalse(window.isExhausted)
    }

    func testDetailLimitsUseNamesAndDeriveRemaining() async {
        let result = await read(#"{"limits":[{"name":"5h quota","detail":{"limit":50,"remaining":0}},{"window":{"duration":300,"timeUnit":"MINUTES"},"detail":{"limit":100,"used":10}}]}"#)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].label, "5h quota")
        XCTAssertEqual(result.windows[0].remainingPercent, 0)
        XCTAssertTrue(result.windows[0].isExhausted)
        XCTAssertEqual(result.windows[0].status, .exhausted)
        XCTAssertEqual(result.windows[1].label, "5h limit")
        XCTAssertEqual(result.windows[1].window, "5h")
        XCTAssertEqual(result.windows[1].remainingPercent, 90)
    }

    func testMissingCredentialIsSilent() async {
        let result = await read("{}", token: nil)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testRejectedSessionIsAnIssue() async {
        let result = await read("{}", status: 401)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["kimi"], "Kimi session was rejected; sign in again in Kimi Code.")
    }

    func testUnparseableSuccessIsAnIssueNotAWindow() async {
        let result = await read(#"{"unexpected":true}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["kimi"], "Kimi returned no readable quota.")
    }

    func testTransportFailureIsAnIssue() async {
        let result = await KimiQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { "token" },
            fetch: { _ in throw URLError(.notConnectedToInternet) }
        ).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["kimi"], "Kimi quota service is unavailable.")
    }
}
