import Foundation
import XCTest
@testable import QuotaCore

/// The reader walks ZCode's own project-token chain before the quota call,
/// so every stub routes by request path and can record what was sent.
final class ZCodeQuotaReaderTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        func add(_ request: URLRequest) { lock.lock(); seen.append(request); lock.unlock() }
        func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private let customerJSON = #"{"code":200,"data":{"organizations":[{"organizationId":"o1","organizationName":"默认机构","projects":[{"projectId":"p1","projectName":"默认项目","projectType":1}]}]}}"#
    private let keysJSON = #"{"code":200,"data":[{"name":"zcode-api-key","apiKey":"key-id-1"}]}"#
    private let mintJSON = #"{"code":200,"data":{"enable":true,"accessToken":"proj-tok","expiresAt":9999999999,"expiresIn":3600}}"#

    private struct Stub {
        var quotaJSON: String
        var quotaStatus: Int = 200
        var customerJSON: String?
        var customerStatus: Int = 200
        var keysJSON: String?
        var keysStatus: Int = 200
        var mintJSON: String?
        var mintStatus: Int = 200
    }

    private func read(
        _ stub: Stub,
        store: [String: String]? = ["oauth:zai:access_token": "tok"],
        recorder: Recorder? = nil
    ) async -> LocalQuotaResult {
        let customer = customerJSON
        let keys = keysJSON
        let mint = mintJSON
        return await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { store ?? [:] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { request in
                recorder?.add(request)
                let path = request.url?.path ?? ""
                let body: String
                let status: Int
                if path.hasSuffix("/api/biz/customer/getCustomerInfo") {
                    body = stub.customerJSON ?? customer
                    status = stub.customerStatus
                } else if path.hasSuffix("/access_tokens") {
                    body = stub.mintJSON ?? mint
                    status = stub.mintStatus
                } else if path.contains("/api_keys") {
                    body = stub.keysJSON ?? keys
                    status = stub.keysStatus
                } else {
                    body = stub.quotaJSON
                    status = stub.quotaStatus
                }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status, httpVersion: nil, headerFields: nil
                )!
                return (Data(body.utf8), response)
            }
        ).read()
    }

    // MARK: - Chain contract

    func testChainSendsTheContractCredentials() async {
        let recorder = Recorder()
        let result = await read(Stub(quotaJSON: #"{"code":200,"data":{"level":"pro","limits":[{"type":"CREDIT_LIMIT","unit":3,"percentage":40,"currentValue":1000,"remaining":600}]}}"#), recorder: recorder)
        XCTAssertEqual(result.windows.count, 1)
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 4, "customerInfo, key list, mint, quota - in that order")
        XCTAssertTrue(requests[0].url!.path.hasSuffix("/api/biz/customer/getCustomerInfo"))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "authorization"), "tok", "customerInfo is tried with the raw login token first")
        XCTAssertEqual(requests[1].url!.path, "/api/biz/v1/organization/o1/projects/p1/api_keys")
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "authorization"), "Bearer tok", "personal key management keeps the z.ai Bearer form")
        XCTAssertTrue(requests[2].url!.path.hasSuffix("/api_keys/key-id-1/access_tokens"))
        XCTAssertEqual(requests[2].httpMethod, "POST")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "authorization"), "Bearer tok", "the mint is Bearer for both families")
        let mintBody = (try? JSONSerialization.jsonObject(with: requests[2].httpBody ?? Data())) as? [String: Any]
        XCTAssertEqual(mintBody?["clientType"] as? String, "zcode")
        XCTAssertEqual(mintBody?["clientVersion"] as? String, "3.16.3")
        XCTAssertEqual(requests[3].url!.path, "/api/monitor/usage/quota/limit")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "authorization"), "Bearer proj-tok", "the quota call presents the minted project token, never the raw login token")
    }

    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [(Int, String)]
        init(_ answers: [(Int, String)]) { self.answers = answers }
        func next(fallback: (Int, String)) -> (Int, String) {
            lock.lock(); defer { lock.unlock() }
            return answers.isEmpty ? fallback : answers.removeFirst()
        }
    }

    func testCustomerInfoRetriesBearerOnlyAfterAnAuthRejection() async {
        let recorder = Recorder()
        let customer = customerJSON
        let keys = keysJSON
        let mint = mintJSON
        let answers = AnswerBox([(401, "{}"), (200, customer)])
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok"] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { request in
                recorder.add(request)
                let path = request.url?.path ?? ""
                var body = ""
                var status = 200
                if path.hasSuffix("/api/biz/customer/getCustomerInfo") {
                    let answer = answers.next(fallback: (200, customer))
                    status = answer.0
                    body = answer.1
                } else if path.hasSuffix("/access_tokens") {
                    body = mint
                } else if path.contains("/api_keys") {
                    body = keys
                } else {
                    body = #"{"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"percentage":10,"remaining":900,"currentValue":100}]}}"#
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        ).read()
        XCTAssertEqual(result.windows.count, 1)
        let headers = recorder.snapshot()
            .filter { $0.url!.path.hasSuffix("/api/biz/customer/getCustomerInfo") }
            .map { $0.value(forHTTPHeaderField: "authorization") }
        XCTAssertEqual(headers, ["tok", "Bearer tok"], "raw first, Bearer only after the HTTP 401")
    }

    func testCustomerInfoRejectedOnBothFormsMeansSignInAgain() async {
        let result = await read(Stub(quotaJSON: "{}", customerStatus: 401))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode session was rejected; sign in again in ZCode.")
    }

    func testBigmodelChainUsesRawKeyListAuthAndNoFallback() async {
        let recorder = Recorder()
        let result = await read(
            Stub(quotaJSON: #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#),
            store: ["oauth:bigmodel:access_token": "bm-tok"],
            recorder: recorder
        )
        XCTAssertEqual(result.windows.count, 1)
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 4, "no Bearer retry for bigmodel: the bracket agrees on raw customerInfo there")
        XCTAssertEqual(requests[0].url!.host, "bigmodel.cn")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "authorization"), "bm-tok")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "authorization"), "bm-tok", "bigmodel key management is the raw token")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "authorization"), "Bearer bm-tok")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "authorization"), "Bearer proj-tok")
    }

    // MARK: - Honest account issues (never a mutation)

    func testMissingNamedKeyIsAnIssueAndNeverCreates() async {
        let recorder = Recorder()
        let result = await read(Stub(quotaJSON: "{}", keysJSON: #"{"code":200,"data":[{"name":"other-key","apiKey":"k2"}]}"#), recorder: recorder)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode account has no coding-plan API key yet; open ZCode once to finish the coding-plan setup.")
        let creations = recorder.snapshot().filter { $0.url!.path.hasSuffix("/api_keys") && $0.httpMethod == "POST" }
        XCTAssertTrue(creations.isEmpty, "the reader lists keys only; it never creates one")
    }

    func testDisabledTokenIsAnIssue() async {
        let result = await read(Stub(quotaJSON: "{}", mintJSON: #"{"code":200,"data":{"enable":false}}"#))
        XCTAssertEqual(result.issues["zcode"], "ZCode reports the coding-plan token disabled.")
    }

    func testMintKeyGoneIsAnIssue() async {
        let result = await read(Stub(quotaJSON: "{}", mintJSON: #"{"code":404,"msg":"gone"}"#))
        XCTAssertEqual(result.issues["zcode"], "ZCode's coding-plan key no longer exists; sign in again in ZCode.")
    }

    func testNoPersonalProjectIsAnIssue() async {
        let teams = #"{"code":200,"data":{"organizations":[{"organizationId":"o9","organizationName":"团队","projects":[{"projectId":"p9","projectName":"团队项目","projectType":2}]}]}}"#
        let result = await read(Stub(quotaJSON: "{}", customerJSON: teams))
        XCTAssertEqual(result.issues["zcode"], "ZCode sign-in has no selectable personal project.")
    }

    func testQuotaRejectedAfterMintMeansSignInAgain() async {
        let result = await read(Stub(quotaJSON: "{}", quotaStatus: 401))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode session was rejected; sign in again in ZCode.")
    }

    func testChainAccountIssueFallsThroughToAHealthySecondAccount() async {
        let customer = customerJSON
        let keys = keysJSON
        let mint = mintJSON
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok", "oauth:bigmodel:access_token": "bm-tok"] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { request in
                let host = request.url?.host ?? ""
                let path = request.url?.path ?? ""
                let body: String
                if path.hasSuffix("/api/biz/customer/getCustomerInfo") {
                    body = host == "api.z.ai"
                        ? #"{"code":200,"data":{"organizations":[]}}"#
                        : customer
                } else if path.hasSuffix("/access_tokens") {
                    body = mint
                } else if path.contains("/api_keys") {
                    body = keys
                } else {
                    body = #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        ).read()
        XCTAssertEqual(result.windows.count, 1, "a broken z.ai chain must not mask a working bigmodel account")
        XCTAssertEqual(result.windows[0].quotaUnit, "tokens")
    }

    func testNoPlanFallsThroughToAHealthySecondAccount() async {
        let customer = customerJSON
        let keys = keysJSON
        let mint = mintJSON
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok", "oauth:bigmodel:access_token": "bm-tok"] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { request in
                let host = request.url?.host ?? ""
                let path = request.url?.path ?? ""
                let body: String
                if path.hasSuffix("/api/biz/customer/getCustomerInfo") {
                    body = customer
                } else if path.hasSuffix("/access_tokens") {
                    body = mint
                } else if path.contains("/api_keys") {
                    body = keys
                } else {
                    body = host == "api.z.ai"
                        ? #"{"code":500,"msg":"当前用户不存在coding plan"}"#
                        : #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        ).read()
        XCTAssertEqual(result.windows.count, 1, "z.ai's no-plan answer must not mask bigmodel's quota")
        XCTAssertEqual(result.windows[0].quotaUnit, "tokens")
    }

    func testEnvelopeAuthFailureOnRawAttemptNeverSwapsTheHeader() async {
        // ZCode's client treats a non-success envelope as an invalid response,
        // not an auth signal: only HTTP 401/403 triggers the Bearer retry.
        let recorder = Recorder()
        let result = await read(
            Stub(quotaJSON: "{}", customerJSON: #"{"code":401,"msg":"unauthorized"}"#),
            recorder: recorder
        )
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (customerInfo step: envelope).")
        let customerCalls = recorder.snapshot().filter { $0.url!.path.hasSuffix("/api/biz/customer/getCustomerInfo") }
        XCTAssertEqual(customerCalls.count, 1, "an envelope-level failure is not an auth rejection: no Bearer retry")
    }

    // MARK: - Quota payload mapping (unchanged contract)

    func testCreditLimitsBecomeFiveHourAndWeeklyWindows() async {
        let result = await read(Stub(quotaJSON: #"{"code":200,"msg":"ok","data":{"level":"pro","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":40,"currentValue":1000,"remaining":600,"nextResetTime":1762531200000},{"type":"CREDIT_LIMIT","unit":6,"percentage":90,"currentValue":5000,"remaining":500}]}}"#))
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
        let result = await read(Stub(quotaJSON: #"{"code":0,"data":{"level":"lite","limits":[{"type":"TIME_LIMIT","unit":5,"percentage":100}]}}"#))
        let window = result.windows[0]
        XCTAssertEqual(window.label, "MCP tool calls")
        XCTAssertEqual(window.window, "monthly")
        XCTAssertEqual(window.quotaUnit, "calls")
        XCTAssertEqual(window.remainingPercent, 0)
        XCTAssertTrue(window.isExhausted)
        XCTAssertTrue(window.skip)
    }

    func testMissingCredentialIsSilent() async {
        let result = await read(Stub(quotaJSON: "{}"), store: nil)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testNoPlanMessageIsAnIssue() async {
        let result = await read(Stub(quotaJSON: #"{"code":500,"msg":"当前用户不存在coding plan"}"#))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "No GLM Coding Plan is active on this ZCode account.")
    }

    func testEmptyLimitsReportNoWindowsForAccount() async {
        // Live-verified account state: a signed-in account whose plan exposes
        // no quota windows answers 200 with an empty limits array. That must
        // read as an empty account, never as "unavailable" or a full quota.
        let result = await read(Stub(quotaJSON: #"{"code":200,"data":{"limits":[]}}"#))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode returned no quota windows for this account.")
    }

    func testUnparseableLimitsReportNoReadableQuota() async {
        let result = await read(Stub(quotaJSON: #"{"code":200,"data":{"limits":[{"unit":6}]}}"#))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode returned no readable quota.")
    }

    func testMissingLimitsKeyReportsNoReadableQuota() async {
        // A 200 envelope whose data omits limits (or mistypes it) is a
        // malformed payload, not a truthful empty account.
        let missing = await read(Stub(quotaJSON: #"{"code":200,"data":{}}"#))
        XCTAssertTrue(missing.windows.isEmpty)
        XCTAssertEqual(missing.issues["zcode"], "ZCode returned no readable quota.")
        let mistyped = await read(Stub(quotaJSON: #"{"code":200,"data":{"limits":"none"}}"#))
        XCTAssertTrue(mistyped.windows.isEmpty)
        XCTAssertEqual(mistyped.issues["zcode"], "ZCode returned no readable quota.")
    }

    func testCancellationIsNotReportedAsTransportFailure() async {
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok"] },
            fetch: { _ in throw CancellationError() }
        ).read()
        XCTAssertEqual(result.issues["zcode"], "ZCode quota refresh was cancelled.")
    }

    func testRejectedSessionIsAnIssue() async {
        let result = await read(Stub(quotaJSON: "{}", quotaStatus: 401))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode session was rejected; sign in again in ZCode.")
    }

    func testEnvelopeFailureWithoutDataIsUnavailable() async {
        let result = await read(Stub(quotaJSON: #"{"code":500,"msg":"boom"}"#))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (quota step: envelope).")
    }

    // MARK: - Step/category diagnostics

    func testHttpFailureNamesStepAndStatus() async {
        let result = await read(Stub(quotaJSON: "{}", customerStatus: 500))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (customerInfo step: http 500).")
    }

    func testMintEnvelopeFailureNamesAccessTokensStep() async {
        let result = await read(Stub(quotaJSON: "{}", mintJSON: #"{"code":500,"msg":"boom"}"#))
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (accessTokens step: envelope).")
    }

    func testMalformedPayloadNamesStep() async {
        let result = await read(Stub(quotaJSON: "{}", customerJSON: "not json"))
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (customerInfo step: malformed response).")
    }

    func testQuotaHttpFailureNamesQuotaStep() async {
        let result = await read(Stub(quotaJSON: "{}", quotaStatus: 502))
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (quota step: http 502).")
    }

    func testTransportFailureNamesStep() async {
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok"] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { _ in throw URLError(.notConnectedToInternet) }
        ).read()
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (customerInfo step: transport).")
    }

    func testFirstUnavailableDetailWinsAcrossCredentials() async {
        // z.ai answers HTTP 500 at customerInfo; bigmodel is unreachable.
        // The first account's detail is the one reported.
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok", "oauth:bigmodel:access_token": "bm-tok"] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { request in
                if request.url?.host == "bigmodel.cn" { throw URLError(.notConnectedToInternet) }
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        ).read()
        XCTAssertEqual(result.issues["zcode"], "ZCode quota service is unavailable (customerInfo step: http 500).")
    }

    func testTransportCancellationStillReportsCancelledNotUnavailable() async {
        // The tagged path must not swallow cancellation into a step report.
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok"] },
            fetch: { _ in throw CancellationError() }
        ).read()
        XCTAssertEqual(result.issues["zcode"], "ZCode quota refresh was cancelled.")
    }

    func testTransportErrorFallsThroughToSecondCredential() async {
        let customer = customerJSON
        let keys = keysJSON
        let mint = mintJSON
        let result = await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credentials: { ["oauth:zai:access_token": "tok", "oauth:bigmodel:access_token": "bm-tok"] },
            zcodeClientVersion: { "3.16.3" },
            fetch: { request in
                if request.url?.host == "api.z.ai" { throw URLError(.notConnectedToInternet) }
                let path = request.url?.path ?? ""
                let body: String
                if path.hasSuffix("/api/biz/customer/getCustomerInfo") {
                    body = customer
                } else if path.hasSuffix("/access_tokens") {
                    body = mint
                } else if path.contains("/api_keys") {
                    body = keys
                } else {
                    body = #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        ).read()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].quotaUnit, "tokens")
    }

    func testFallsBackToBigModelCredential() async {
        let result = await read(
            Stub(quotaJSON: #"{"code":200,"data":{"level":"max","limits":[{"type":"TOKENS_LIMIT","unit":6,"percentage":5}]}}"#),
            store: ["oauth:bigmodel:access_token": "bm-tok"]
        )
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].quotaUnit, "tokens")
        XCTAssertEqual(result.windows[0].planName, "GLM Coding Max")
    }
}

import Foundation
import XCTest
@testable import QuotaCore

final class ExplicitZCodeQuotaReaderTests: XCTestCase {
    private func read(
        _ json: String,
        status: Int = 200,
        credential: ZCodeQuotaCredential? = .init(region: .zAI, apiKey: "fixture-api-key")
    ) async -> LocalQuotaResult {
        await ZCodeQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            credential: { credential },
            credentials: {
                if credential != nil { XCTFail("An explicit credential must not read the local OAuth store") }
                return [:]
            },
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

    func testAbsentExplicitAndLocalCredentialsStaySilentWithoutFetching() async {
        let result = await read("{}", credential: nil)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
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

    func testNoSavedKeyAndNoLocalSignInNeverAttemptQuotaCalls() async {
        let result = await ZCodeQuotaReader(credentials: { [:] }, fetch: { _ in
            XCTFail("No saved key or local sign-in means no request")
            throw URLError(.badURL)
        }).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
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
