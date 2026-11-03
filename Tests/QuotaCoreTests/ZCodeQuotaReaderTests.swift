import Foundation
import XCTest
@testable import QuotaCore

final class ZCodeQuotaReaderTests: XCTestCase {
    private func read(
        _ json: String,
        status: Int = 200,
        credential: ZCodeQuotaCredential? = .init(region: .zAI, apiKey: "fixture-api-key")
    ) async -> LocalQuotaResult {
        await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credential: { credential },
            fetch: { request in
                XCTAssertEqual(request.url, credential?.region.quotaURL)
                let authorization = request.value(forHTTPHeaderField: "authorization")
                if status == 401, let key = credential?.apiKey {
                    XCTAssertTrue(authorization == key || authorization == "Bearer " + key)
                } else { XCTAssertEqual(authorization, credential?.apiKey) }
                let response = HTTPURLResponse(
                    url: request.url!,
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
        XCTAssertEqual(fiveHour.providerLabel, "Z.ai")
        XCTAssertEqual(fiveHour.label, "5-hour limit")
        XCTAssertEqual(fiveHour.window, "5h")
        // percentage is the USED share; the row shows what remains.
        XCTAssertEqual(fiveHour.remainingPercent, 60)
        XCTAssertEqual(fiveHour.absoluteRemaining, 600)
        // The cap is remaining + consumed; currentValue alone is usage.
        XCTAssertEqual(fiveHour.absoluteLimit, 1600)
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

    func testMissingCredentialReportsSetupNeededWithoutFetching() async {
        let result = await read("{}", credential: nil)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues["zcode"]?.contains("setup is needed") == true)
    }

    func testNoPlanMessageIsAnIssue() async {
        let result = await read(#"{"code":500,"msg":"当前用户不存在coding plan"}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "No GLM Coding Plan is active on this account.")
    }

    func testEmptyLimitsReportNoWindowsForAccount() async {
        // Live-verified account state: a signed-in account whose plan exposes
        // no quota windows answers 200 with an empty limits array. That must
        // read as an empty account, never as "unavailable" or a full quota.
        let result = await read(#"{"code":200,"data":{"limits":[]}}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "Z.ai returned no quota windows for this account.")
    }

    func testUnparseableLimitsReportNoReadableQuota() async {
        let result = await read(#"{"code":200,"data":{"limits":[{"unit":6}]}}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "Z.ai returned no readable quota.")
    }

    func testMissingLimitsKeyReportsNoReadableQuota() async {
        // A 200 envelope whose data omits limits (or mistypes it) is a
        // malformed payload, not a truthful empty account.
        let missing = await read(#"{"code":200,"data":{}}"#)
        XCTAssertTrue(missing.windows.isEmpty)
        XCTAssertEqual(missing.issues["zcode"], "Z.ai returned no readable quota.")
        let mistyped = await read(#"{"code":200,"data":{"limits":"none"}}"#)
        XCTAssertTrue(mistyped.windows.isEmpty)
        XCTAssertEqual(mistyped.issues["zcode"], "Z.ai returned no readable quota.")
    }

    func testCancellationIsNotReportedAsTransportFailure() async {
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credential: { .init(region: .zAI, apiKey: "fixture-api-key") },
            fetch: { _ in throw CancellationError() }
        ).read()
        XCTAssertEqual(result.issues["zcode"], "Z.ai quota refresh was cancelled.")
    }

    func testRejectedSessionIsAnIssue() async {
        let result = await read("{}", status: 401)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "The saved Coding Plan API key was rejected.")
    }

    func testEnvelopeFailureWithoutDataIsUnavailable() async {
        let result = await read(#"{"code":500,"msg":"boom"}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "Z.ai quota service is unavailable.")
    }

    func testTransportFailureNeverSendsTheKeyToAnotherRegion() async {
        let counter = ZCodeRequestCounter()
        let result = await ZCodeQuotaReader(credential: { .init(region: .zAI, apiKey: "fixture-api-key") },
            fetch: { request in
                await counter.increment()
                XCTAssertEqual(request.url?.host, "api.z.ai")
                throw URLError(.notConnectedToInternet)
            }).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "Z.ai quota service is unavailable.")
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testBigModelKeyUsesOnlyItsPairedRegionalEndpoint() async {
        let result = await read(
            #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#,
            credential: .init(region: .bigModel, apiKey: "bigmodel-fixture-key")
        )
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].quotaUnit, "tokens")
        XCTAssertEqual(result.windows[0].planName, "GLM Coding Max")
    }
    func testURLCancellationDoesNotTryAnotherAuthenticationFormOrAccount() async {
        let counter = ZCodeRequestCounter()
        let result = await ZCodeQuotaReader(credential: {
            .init(region: .zAI, apiKey: "fixture-api-key")
        }, fetch: { _ in
            await counter.increment()
            throw URLError(.cancelled)
        }).read()
        XCTAssertEqual(result.issues["zcode"], "Z.ai quota refresh was cancelled.")
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testDefaultReaderNeedsExplicitSetupAndNeverAttemptsOAuthOrQuotaCalls() async {
        let result = await ZCodeQuotaReader(fetch: { _ in
            XCTFail("No explicit Coding Plan key means no request")
            throw URLError(.badURL)
        }).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues["zcode"]?.contains("setup is needed") == true)
    }

    func testInvalidSavedKeyCannotReachTransport() async {
        var invalid = ZCodeQuotaCredential(region: .zAI, apiKey: "fixture-key")
        invalid.apiKey = "first\nsecond"
        let saved = invalid
        let result = await ZCodeQuotaReader(credential: { saved }, fetch: { _ in
            XCTFail("An invalid saved key must not reach quota transport")
            throw URLError(.badURL)
        }).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues["zcode"]?.contains("setup is needed") == true)
    }

    func testRejectedKeyCannotFallBackToAnotherRegion() async {
        let counter = ZCodeRequestCounter()
        let result = await ZCodeQuotaReader(credential: { .init(region: .zAI, apiKey: "fixture-api-key") }, fetch: { request in
            await counter.increment()
            XCTAssertEqual(request.url?.host, "api.z.ai")
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }).read()
        let count = await counter.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(result.issues["zcode"], "The saved Coding Plan API key was rejected.")
    }

}


private actor ZCodeRequestCounter {
    var count = 0
    func increment() { count += 1 }
}
