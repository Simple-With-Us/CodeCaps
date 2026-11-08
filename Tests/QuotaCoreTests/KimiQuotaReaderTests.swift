import Foundation
import XCTest
@testable import QuotaCore

final class KimiQuotaReaderTests: XCTestCase {
    /// Keeps the reader's environment overrides from pointing a fixture
    /// test at this Mac's real credential store, restoring both values
    /// afterwards.
    private func withoutCredentialEnvironment<T>(_ body: () throws -> T) rethrows -> T {
        let saved: [(String, String?)] = [
            ("KIMI_CODE_HOME", getenv("KIMI_CODE_HOME").map { String(cString: $0) }),
            ("KIMI_SHARE_DIR", getenv("KIMI_SHARE_DIR").map { String(cString: $0) }),
        ]
        for (key, _) in saved { unsetenv(key) }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        return try body()
    }

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

    /// The live `/usages` shape: int64 counts quoted as strings, `resetTime`,
    /// `TIME_UNIT_*` enum names and sibling objects this reader ignores.  The
    /// counts are synthetic; the shape is the one the Kimi CLI's own parser
    /// reads (counts through `toInt`, units `TIME_UNIT_MINUTE`, `HOUR`, `DAY`
    /// and `WEEK`).  Every older fixture here uses bare numbers, which is how
    /// the reader came to drop every window on the real payload.
    func testLiveShapeQuotedCountsAndEnumUnits() async {
        let result = await read(#"{"user":{"userId":"u1","region":"REGION_OVERSEA"},"usage":{"limit":"100","remaining":"69","resetTime":"2026-11-11T01:02:55Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","remaining":"40","resetTime":"2026-11-06T22:00:00Z"}}],"parallel":{"limit":"20"},"totalQuota":{"limit":"100","remaining":"100"},"authentication":{"method":"METHOD_OAUTH","scope":"FEATURE_CODING"},"subType":"TYPE_PURCHASE"}"#)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 2)
        let weekly = result.windows[0]
        XCTAssertEqual(weekly.label, "Weekly limit")
        XCTAssertEqual(weekly.remainingPercent, 69)
        XCTAssertEqual(weekly.absoluteRemaining, 69)
        XCTAssertEqual(weekly.absoluteLimit, 100)
        XCTAssertEqual(weekly.resetAt, "2026-11-11T01:02:55Z")
        let fiveHour = result.windows[1]
        XCTAssertEqual(fiveHour.label, "5h limit")
        XCTAssertEqual(fiveHour.window, "5h")
        XCTAssertEqual(fiveHour.remainingPercent, 40)
        XCTAssertEqual(fiveHour.resetAt, "2026-11-06T22:00:00Z")
    }

    func testWeekUnitLimitIsLabelledAsAWeek() async {
        let result = await read(#"{"limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":"200","remaining":"50"}},{"window":{"duration":2,"timeUnit":"TIME_UNIT_WEEK"},"detail":{"limit":"10","remaining":"10"}}]}"#)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].label, "1w limit")
        XCTAssertEqual(result.windows[0].window, "weekly")
        XCTAssertEqual(result.windows[0].remainingPercent, 25)
        XCTAssertEqual(result.windows[1].label, "2w limit")
        XCTAssertEqual(result.windows[1].window, "2w")
    }

    func testCountsAcceptPlainDecimalStringsOnly() {
        XCTAssertEqual(KimiQuotaReader.int("300"), 300)
        XCTAssertEqual(KimiQuotaReader.int(" 7 "), 7)
        XCTAssertEqual(KimiQuotaReader.int(NSNumber(value: 3)), 3)
        for bad in ["", "abc", "-1", "+1", "1e3", "0x10", "1.2.3", "7.5", "NaN", "inf", String(repeating: "9", count: 40)] {
            XCTAssertNil(KimiQuotaReader.int(bad), bad)
        }
        XCTAssertNil(KimiQuotaReader.int(true))
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

    func testExpiredStoredTokenReportsRefreshNotRejection() async {
        // Live-verified 2026-11-04: the CLI's 15-minute access token expires
        // whenever the CLI has been idle, the server then 401s, and the
        // sign-in itself is fine.  A credential the file marks expired is a
        // refresh wait, not a dead session.
        let result = await KimiQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { "token" },
            credentialExpiresAt: { Date(timeIntervalSince1970: -60) },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.kimi.com/coding/v1/usages")!,
                    statusCode: 401, httpVersion: nil, headerFields: nil
                )!
                return (Data("{}".utf8), response)
            }
        ).read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.issues["kimi"], "Kimi's stored access token has expired; open Kimi Code to refresh it.")
    }

    func testFutureExpiryWithRejectionStillAsksForSignIn() async {
        let result = await KimiQuotaReader(
            now: { Date(timeIntervalSince1970: 0) },
            accessToken: { "token" },
            credentialExpiresAt: { Date(timeIntervalSince1970: 60) },
            fetch: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.kimi.com/coding/v1/usages")!,
                    statusCode: 401, httpVersion: nil, headerFields: nil
                )!
                return (Data("{}".utf8), response)
            }
        ).read()
        XCTAssertEqual(result.issues["kimi"], "Kimi session was rejected; sign in again in Kimi Code.")
    }

    func testReadLocalCredentialReadsExpiryFromTheFile() throws {
        try withoutCredentialEnvironment {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let credentials = home.appendingPathComponent(".kimi-code/credentials")
            try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            try """
            {"access_token": "tok", "refresh_token": "r", "expires_at": 1788332693, "expires_in": 900}
            """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
            let credential = KimiQuotaReader.readLocalCredential(home: home)
            XCTAssertEqual(credential?.token, "tok")
            XCTAssertEqual(credential?.expiresAt, Date(timeIntervalSince1970: 1_788_332_693))
        }
    }

    func testCredentialExpiryAcceptsMillisecondsAndIsoStamp() {
        XCTAssertEqual(KimiQuotaReader.credentialExpiry(1_788_332_693_000), Date(timeIntervalSince1970: 1_788_332_693))
        XCTAssertEqual(KimiQuotaReader.credentialExpiry("2026-09-02T07:04:53Z"), Date(timeIntervalSince1970: 1_788_332_693))
        XCTAssertNil(KimiQuotaReader.credentialExpiry("not a date"))
        XCTAssertNil(KimiQuotaReader.credentialExpiry(nil))
    }

    /// Seen live on 2026-11-06: a signed-in Kimi account with no Kimi Code plan
    /// answers `/usages` with 200 and `{}`.  That is "no plan", not an unreadable
    /// quota, so it stays silent like a missing sign-in.
    func testEmptyPayloadMeansNoPlanAndIsSilent() async {
        let result = await read("{}")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
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
        try withoutCredentialEnvironment {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let credentials = home.appendingPathComponent(".kimi-code/credentials")
            try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let token = "eyJ" + String(repeating: "a", count: 500)
            try """
            {"access_token": "\(token)", "refresh_token": "r", "expires_at": 1, "scope": "s", "token_type": "Bearer", "expires_in": 1}
            """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
            XCTAssertEqual(KimiQuotaReader.readLocalAccessToken(home: home), token)
        }
    }

    func testCredentialFileRejectsOversizedAndMultilineTokens() throws {
        try withoutCredentialEnvironment {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let credentials = home.appendingPathComponent(".kimi-code/credentials")
            try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let oversized = String(repeating: "a", count: 8_193)
            try """
            {"access_token": "\(oversized)"}
            """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
            XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home), "beyond the 8 KB token bound is not a credential")
            try """
            {"access_token": "line1\\nline2"}
            """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
            XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home), "a CR/LF in the value is not a credential")
        }
    }

    func testConfigTomlRequiresExactKeyAndStripsInlineComment() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        api_key_backup = "wrong-token"
        api_key = "sk-test-token" # rotated
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(KimiQuotaReader.configToken(root: home), "sk-test-token")
    }
}
