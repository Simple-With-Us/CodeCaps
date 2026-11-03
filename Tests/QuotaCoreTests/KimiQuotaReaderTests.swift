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
        XCTAssertNil(window.quotaUnit, "The provider does not establish a physical unit for these quota counters")
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

    func testCancellationIsNotReportedAsTransportFailure() async {
        let result = await KimiQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { "tok" },
            fetch: { _ in throw CancellationError() }
        ).read()
        XCTAssertEqual(result.issues["kimi"], "Kimi quota refresh was cancelled.")
    }

    func testIntRejectsOutOfRangeAndFractionalValues() {
        XCTAssertNil(KimiQuotaReader.int(pow(2.0, 63.0)))
        XCTAssertNil(KimiQuotaReader.int(5.5))
        XCTAssertEqual(KimiQuotaReader.int(5.0), 5)
        XCTAssertEqual(KimiQuotaReader.int(0.0), 0)
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
        XCTAssertEqual(result.issues["kimi"], "Kimi quota service could not be reached.")
    }

    func testTransportErrorFallsThroughToSecondHost() async {
        let result = await KimiQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { "token" },
            fetch: { request in
                if request.url?.host == "api.kimi.com" { throw URLError(.cannotFindHost) }
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.kimi.ai/coding/v1/usages")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (Data(#"{"usage":{"limit":100,"used":25}}"#.utf8), response)
            }
        ).read()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].remainingPercent, 75)
    }

    func testCredentialFileAcceptsRealLengthOauthToken() throws {
        // Regression: the shared label helper caps at 160 bytes, which read a
        // real signed-in account (OAuth tokens are routinely far longer) as
        // "no local sign-in" - empty windows with no issue.  The credential
        // path must use only the token predicate (8 KB, no CR/LF).
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = home.appendingPathComponent(".kimi-code/credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let token = "eyJ" + String(repeating: "a", count: 500)
        try """
        {"access_token": "\(token)", "refresh_token": "r", "expires_at": 1, "scope": "s", "token_type": "Bearer", "expires_in": 1}
        """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(KimiQuotaReader.readLocalAccessToken(home: home, environment: [:]), token)
    }

    func testCredentialFileRejectsOversizedAndMultilineTokens() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let credentials = home.appendingPathComponent(".kimi-code/credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let oversized = String(repeating: "a", count: 8_193)
        try """
        {"access_token": "\(oversized)"}
        """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home, environment: [:]), "beyond the 8 KB token bound is not a credential")
        try """
        {"access_token": "line1\\nline2"}
        """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home, environment: [:]), "a CR/LF in the value is not a credential")
    }

    func testConfigTomlCRLFSelectsApprovedKimiKeyAcrossProvidersAndComments() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let lines = [
            "# provider credentials",
            "[providers.anthropic]",
            "type = \"anthropic\"",
            "base_url = \"https://api.anthropic.com/v1\"",
            "api_key = \"other-provider-fixture\"",
            "[providers.\"managed:kimi-code\"]",
            "type = \"kimi\"",
            "base_url = \"https://api.kimi.com/coding/v1\"",
            "# api_key = \"commented-out-fixture\"",
            "api_key = \"kimi-crlf-fixture\""
        ]
        try (lines.joined(separator: "\r\n") + "\r\n").write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(KimiQuotaReader.configToken(root: home), "kimi-crlf-fixture")
    }

    func testConfigTomlRequiresExactKeyAndStripsInlineComment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"
        api_key_backup = "wrong-token"
        api_key = "sk-test-token" # rotated
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(KimiQuotaReader.configToken(root: home), "sk-test-token")
    }
    func testOfficialNumericStringCountersAndDurationProduceQuotaWindows() async {
        let result = await read(#"{"usage":{"limit":"100","used":"29","remaining":"71"},"limits":[{"window":{"duration":"300","timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"12"}}]}"#)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows.first?.remainingPercent, 71)
        XCTAssertEqual(result.windows.last?.remainingPercent, 12)
        XCTAssertEqual(result.windows.last?.window, "5h")
    }

    func testNumericStringsPreserveFiniteNonnegativeAndExactIntegerGuards() async {
        XCTAssertEqual(KimiQuotaReader.int("300"), 300)
        XCTAssertEqual(KimiQuotaReader.int(" 5 "), 5)
        let invalid: [Any?] = [nil, true, false, "NaN", "inf", "-1", "5.5", "1e309", "9223372036854775808"]
        for value in invalid { XCTAssertNil(KimiQuotaReader.int(value)) }
        let result = await read(#"{"usage":{"limit":"NaN","used":true},"limits":[{"detail":{"limit":"-1","used":"Infinity"}}]}"#)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["kimi"], "Kimi returned no readable quota.")
    }

    func testOtherProviderKeyCannotReachTheKimiTransport() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".kimi-code")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [providers.openai]
        type = "openai"
        base_url = "https://api.openai.com/v1"
        api_key = "other-provider-fixture"
        [services.moonshot_search]
        api_key = "service-fixture"
        """.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let result = await KimiQuotaReader(accessToken: {
            KimiQuotaReader.readLocalAccessToken(home: home, environment: [:])
        }, fetch: { _ in
            XCTFail("An unrelated provider or service credential must never reach a Kimi request")
            throw URLError(.badURL)
        }).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMultipleProvidersSelectTheExplicitKimiCodingProvider() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".kimi-code")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        [providers.anthropic]
        type = "anthropic"
        base_url = "https://api.anthropic.com/v1"
        api_key = "other-provider-fixture"
        [providers."managed:kimi-code"]
        type = "kimi"
        api_key = "kimi-fixture"
        base_url = "https://api.kimi.ai/coding/v1/"
        [services.moonshot_fetch]
        api_key = "service-fixture"
        """.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let counter = KimiRequestCounter()
        let result = await KimiQuotaReader(accessToken: {
            KimiQuotaReader.readLocalAccessToken(home: home, environment: [:])
        }, fetch: { request in
            await counter.increment()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer kimi-fixture")
            return (Data(#"{"usage":{"limit":"100","remaining":"75"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }).read()
        XCTAssertEqual(result.windows.first?.remainingPercent, 75)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testConfigFallbackRejectsUnscopedKeysAndUnapprovedCodingBases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for base in ["http://api.kimi.com/coding/v1", "https://api.kimi.com.evil.invalid/coding/v1",
                     "https://api.kimi.com/v1", "https://api.kimi.com/coding/v1?redirect=1",
                     "https://user@api.kimi.com/coding/v1", "https://api.kimi.com:8443/coding/v1"] {
            try """
            [providers."managed:kimi-code"]
            type = "kimi"
            base_url = "\(base)"
            api_key = "kimi-fixture"
            """.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            XCTAssertNil(KimiQuotaReader.configToken(root: root))
        }
        try #"api_key = "unscoped-fixture""#.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertNil(KimiQuotaReader.configToken(root: root))
    }

    func testConfigJSONAcceptsLongRawKimiTokenButRejectsOtherProvidersAndMalformedTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        let longToken = String(repeating: "a", count: 512)
        let kimi: [String: Any] = ["type": "kimi", "base_url": "https://api.kimi.com/coding/v1", "api_key": longToken]
        try JSONSerialization.data(withJSONObject: ["providers": ["other": ["type": "openai", "api_key": "foreign-fixture"],
                                                                         "managed:kimi-code": kimi]]).write(to: file)
        XCTAssertEqual(KimiQuotaReader.configToken(root: root), longToken)
        for token in [String(repeating: "a", count: 8_193), "first\nsecond", "first\rsecond"] {
            var invalid = kimi
            invalid["api_key"] = token
            try JSONSerialization.data(withJSONObject: ["providers": ["managed:kimi-code": invalid]]).write(to: file)
            XCTAssertNil(KimiQuotaReader.configToken(root: root))
        }
        try JSONSerialization.data(withJSONObject: ["provider": "openai", "base_url": "https://api.openai.com/v1", "api_key": "foreign-fixture"]).write(to: file)
        XCTAssertNil(KimiQuotaReader.configToken(root: root))
        try JSONSerialization.data(withJSONObject: ["provider": "kimi-code", "baseUrl": "https://api.kimi.ai/coding/v1", "apiKey": longToken]).write(to: file)
        XCTAssertEqual(KimiQuotaReader.configToken(root: root), longToken)
    }

    func testOnlyTheDesignatedOAuthCredentialIsReadAndItPrecedesConfigKeys() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent(".kimi-code")
        let credentials = root.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try JSONSerialization.data(withJSONObject: ["access_token": "foreign-oauth-fixture"])
            .write(to: credentials.appendingPathComponent("another-provider.json"))
        XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home, environment: [:]))
        try JSONSerialization.data(withJSONObject: ["access_token": "kimi-oauth-fixture"])
            .write(to: credentials.appendingPathComponent("kimi-code.json"))
        try """
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"
        api_key = "kimi-api-key-fixture"
        """.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(KimiQuotaReader.readLocalAccessToken(home: home, environment: [:]), "kimi-oauth-fixture")
    }

    func testURLCancellationDoesNotTryTheFallbackHost() async {
        let counter = KimiRequestCounter()
        let result = await KimiQuotaReader(accessToken: { "fixture-token" }, fetch: { _ in
            await counter.increment()
            throw URLError(.cancelled)
        }).read()
        XCTAssertEqual(result.issues["kimi"], "Kimi quota refresh was cancelled.")
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

}


private actor KimiRequestCounter {
    var count = 0
    func increment() { count += 1 }
}
