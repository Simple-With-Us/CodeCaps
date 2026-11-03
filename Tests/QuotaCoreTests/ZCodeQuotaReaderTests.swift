import Foundation
import XCTest
@testable import QuotaCore

final class ZCodeQuotaReaderTests: XCTestCase {
    private func read(
        _ json: String,
        status: Int = 200,
        store: [String: String]? = ["oauth:zai:access_token": "tok"]
    ) async -> LocalQuotaResult {
        await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { store ?? [:] },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!,
                    statusCode: status, httpVersion: nil, headerFields: nil
                )!
                return (Data(json.utf8), response)
            }
        ).read()
    }

    func testCreditLimitsBecomeFiveHourAndWeeklyWindows() async {
        let result = await read(#"{"code":200,"msg":"ok","data":{"level":"pro","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":40,"currentValue":1000,"remaining":600,"nextResetTime":1762531200000},{"type":"CREDIT_LIMIT","unit":6,"percentage":90,"currentValue":5000,"remaining":500}]}}"#)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 2)
        let fiveHour = result.windows[0]
        XCTAssertEqual(fiveHour.providerKey, "zcode")
        XCTAssertEqual(fiveHour.providerLabel, "ZCode")
        XCTAssertEqual(fiveHour.label, "5-hour limit")
        XCTAssertEqual(fiveHour.window, "5h")
        // percentage is the USED share; the row shows what remains.
        XCTAssertEqual(fiveHour.remainingPercent, 60)
        XCTAssertEqual(fiveHour.absoluteRemaining, 600)
        XCTAssertEqual(fiveHour.absoluteLimit, 1000)
        XCTAssertEqual(fiveHour.quotaUnit, "credits")
        XCTAssertEqual(fiveHour.planName, "GLM Coding Pro")
        XCTAssertNotNil(fiveHour.resetAt)
        let weekly = result.windows[1]
        XCTAssertEqual(weekly.label, "Weekly limit")
        XCTAssertEqual(weekly.window, "weekly")
        XCTAssertEqual(weekly.remainingPercent, 10)
        XCTAssertEqual(weekly.status, .nearCap)
    }

    func testTimeLimitIsTheMonthlyToolQuota() async {
        let result = await read(#"{"code":0,"data":{"level":"lite","limits":[{"type":"TIME_LIMIT","unit":5,"percentage":100}]}}"#)
        let window = result.windows[0]
        XCTAssertEqual(window.label, "MCP tool calls")
        XCTAssertEqual(window.window, "monthly")
        XCTAssertEqual(window.quotaUnit, "calls")
        XCTAssertEqual(window.remainingPercent, 0)
        XCTAssertTrue(window.isExhausted)
        XCTAssertTrue(window.skip)
    }

    func testMissingCredentialIsSilent() async {
        let result = await read("{}", store: nil)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testNoPlanMessageIsAnIssue() async {
        let result = await read(#"{"code":500,"msg":"当前用户不存在coding plan"}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "No GLM Coding Plan is active on this ZCode account.")
    }

    func testRejectedSessionIsAnIssue() async {
        let result = await read("{}", status: 401)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode session was rejected; sign in again in ZCode.")
    }

    func testEnvelopeFailureWithoutDataIsUnavailable() async {
        let result = await read(#"{"code":500,"msg":"boom"}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable.")
    }

    func testFallsBackToBigModelCredential() async {
        let result = await read(
            #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#,
            store: ["oauth:bigmodel:access_token": "bm-tok"]
        )
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].quotaUnit, "tokens")
        XCTAssertEqual(result.windows[0].planName, "GLM Coding Max")
    }
}
