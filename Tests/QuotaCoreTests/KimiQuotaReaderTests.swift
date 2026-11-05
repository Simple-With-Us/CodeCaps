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

    func testCredentialExpiryAcceptsMillisecondsAndIsoStamp() {
        XCTAssertEqual(KimiQuotaReader.credentialExpiry(1_788_332_693_000), Date(timeIntervalSince1970: 1_788_332_693))
        XCTAssertEqual(KimiQuotaReader.credentialExpiry("2026-09-02T07:04:53Z"), Date(timeIntervalSince1970: 1_788_332_693))
        XCTAssertNil(KimiQuotaReader.credentialExpiry("not a date"))
        XCTAssertNil(KimiQuotaReader.credentialExpiry(nil))
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
        XCTAssertEqual(KimiQuotaReader.readLocalAccessToken(home: home), token)
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
        XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home), "beyond the 8 KB token bound is not a credential")
        try """
        {"access_token": "line1\\nline2"}
        """.write(to: credentials.appendingPathComponent("kimi-code.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(KimiQuotaReader.readLocalAccessToken(home: home), "a CR/LF in the value is not a credential")
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
