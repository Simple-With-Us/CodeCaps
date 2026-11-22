import Foundation
import XCTest
@testable import QuotaCore

final class ClaudeCredentialRenewerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - The grant request

    func testRefreshRequestMatchesClaudeCodesGrant() throws {
        let request = ClaudeOAuthRefresh.refreshRequest(refreshToken: "saved-refresh")
        XCTAssertEqual(request.url, ClaudeOAuthRefresh.tokenEndpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(json["refresh_token"] as? String, "saved-refresh")
        XCTAssertEqual(json["client_id"] as? String, ClaudeOAuthRefresh.clientID)
    }

    // MARK: - Applying a grant response to the saved record

    func testRefreshedRootAdvancesTokensAndPreservesTheRecord() throws {
        let existing: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "expired-access",
                "refreshToken": "saved-refresh",
                "expiresAt": 1_000,
                "subscriptionType": "max",
                "scopes": ["user:inference"],
            ],
            "sibling": "untouched",
        ]
        let response: [String: Any] = [
            "access_token": "fresh-access",
            "refresh_token": "rotated-refresh",
            "expires_in": 28_800,
        ]
        let updated = try XCTUnwrap(ClaudeOAuthRefresh.refreshedRoot(existing: existing, response: response, now: now))
        XCTAssertEqual(updated["sibling"] as? String, "untouched")
        let record = try XCTUnwrap(updated["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(record["accessToken"] as? String, "fresh-access")
        XCTAssertEqual(record["refreshToken"] as? String, "rotated-refresh")
        XCTAssertEqual(record["subscriptionType"] as? String, "max")
        XCTAssertEqual(record["scopes"] as? [String], ["user:inference"])
        let expiresAt = try XCTUnwrap((record["expiresAt"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(expiresAt, (now.timeIntervalSince1970 + 28_800) * 1000, accuracy: 1)
    }

    func testRefreshedRootKeepsTheSavedRefreshTokenWhenTheResponseOmitsOne() throws {
        let existing: [String: Any] = [
            "claudeAiOauth": ["accessToken": "expired-access", "refreshToken": "saved-refresh", "expiresAt": 1_000],
        ]
        let response: [String: Any] = ["access_token": "fresh-access", "expires_in": 28_800]
        let updated = try XCTUnwrap(ClaudeOAuthRefresh.refreshedRoot(existing: existing, response: response, now: now))
        let record = try XCTUnwrap(updated["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(record["refreshToken"] as? String, "saved-refresh")
    }

    func testRefreshedRootRejectsUnusableResponses() {
        let existing: [String: Any] = [
            "claudeAiOauth": ["accessToken": "expired-access", "refreshToken": "saved-refresh", "expiresAt": 1_000],
        ]
        XCTAssertNil(ClaudeOAuthRefresh.refreshedRoot(existing: existing, response: ["expires_in": 28_800], now: now))
        XCTAssertNil(ClaudeOAuthRefresh.refreshedRoot(
            existing: existing, response: ["access_token": "fresh-access", "expires_in": 0], now: now))
        XCTAssertNil(ClaudeOAuthRefresh.refreshedRoot(
            existing: existing, response: ["access_token": "", "expires_in": 28_800], now: now))
    }

    // MARK: - The renewal flow

    private func renewableRoot(refreshToken: String) -> [String: Any] {
        ["claudeAiOauth": [
            "accessToken": "expired-access",
            "refreshToken": refreshToken,
            "expiresAt": 1_000,
            "subscriptionType": "max",
        ]]
    }

    private func grantResponse(accessToken: String = "fresh-access", refreshToken: String = "rotated-refresh") -> (Data, HTTPURLResponse) {
        let body = Data("{\"access_token\":\"\(accessToken)\",\"refresh_token\":\"\(refreshToken)\",\"expires_in\":28800}".utf8)
        let response = HTTPURLResponse(url: ClaudeOAuthRefresh.tokenEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func testKeychainRenewalWritesBackToTheKeychainOnly() async throws {
        let writes = RenewalWrites()
        let renewer = ClaudeCredentialRenewer(
            readKeychainRoot: { self.renewableRoot(refreshToken: "keychain-refresh") },
            readFileRoot: { [:] },
            fetch: { request in
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["refresh_token"] as? String, "keychain-refresh")
                return self.grantResponse()
            },
            writeKeychain: { data in writes.recordKeychain(data); return true },
            writeFile: { data in writes.recordFile(data); return true },
            remember: { data in writes.recordRemembered(data) },
            now: { self.now })

        let refreshed = await renewer.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertNil(writes.file)
        let written = try XCTUnwrap(writes.keychain)
        XCTAssertEqual(writes.remembered, written)
        let root = try XCTUnwrap(ClaudeOAuthParser.parse(written))
        let record = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(record["accessToken"] as? String, "fresh-access")
        XCTAssertEqual(record["refreshToken"] as? String, "rotated-refresh")
        XCTAssertNotNil(ClaudeOAuthParser.validOAuth(in: root, now: now))
    }

    func testFileRenewalWritesBackToTheFileOnly() async throws {
        let writes = RenewalWrites()
        let renewer = ClaudeCredentialRenewer(
            readKeychainRoot: { [:] },
            readFileRoot: { self.renewableRoot(refreshToken: "file-refresh") },
            fetch: { _ in self.grantResponse() },
            writeKeychain: { data in writes.recordKeychain(data); return true },
            writeFile: { data in writes.recordFile(data); return true },
            remember: { data in writes.recordRemembered(data) },
            now: { self.now })

        let refreshed = await renewer.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertNil(writes.keychain)
        XCTAssertNotNil(writes.file)
    }

    func testARefusedKeychainGrantFallsThroughToTheFileStore() async throws {
        let writes = RenewalWrites()
        let renewer = ClaudeCredentialRenewer(
            readKeychainRoot: { self.renewableRoot(refreshToken: "dead-refresh") },
            readFileRoot: { self.renewableRoot(refreshToken: "file-refresh") },
            fetch: { request in
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if json["refresh_token"] as? String == "dead-refresh" {
                    let response = HTTPURLResponse(url: ClaudeOAuthRefresh.tokenEndpoint, statusCode: 400, httpVersion: nil, headerFields: nil)!
                    return (Data("{\"error\":\"invalid_grant\"}".utf8), response)
                }
                return self.grantResponse()
            },
            writeKeychain: { data in writes.recordKeychain(data); return true },
            writeFile: { data in writes.recordFile(data); return true },
            remember: { data in writes.recordRemembered(data) },
            now: { self.now })

        let refreshed = await renewer.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertNil(writes.keychain)
        XCTAssertNotNil(writes.file)
    }

    func testARefusedGrantWritesNothingAndRemembersNothing() async {
        let writes = RenewalWrites()
        let renewer = ClaudeCredentialRenewer(
            readKeychainRoot: { self.renewableRoot(refreshToken: "dead-refresh") },
            readFileRoot: { [:] },
            fetch: { _ in
                let response = HTTPURLResponse(url: ClaudeOAuthRefresh.tokenEndpoint, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (Data("{\"error\":\"invalid_grant\"}".utf8), response)
            },
            writeKeychain: { data in writes.recordKeychain(data); return true },
            writeFile: { data in writes.recordFile(data); return true },
            remember: { data in writes.recordRemembered(data) },
            now: { self.now })

        let refreshed = await renewer.refresh()
        XCTAssertFalse(refreshed)
        XCTAssertNil(writes.keychain)
        XCTAssertNil(writes.file)
        XCTAssertNil(writes.remembered)
    }

    func testNoRefreshTokenAnywhereNeverFetches() async {
        let fetches = RenewalWrites()
        let renewer = ClaudeCredentialRenewer(
            readKeychainRoot: { ["claudeAiOauth": ["accessToken": "expired-access", "expiresAt": 1_000]] },
            readFileRoot: { [:] },
            fetch: { _ in
                fetches.recordFile(Data())
                return self.grantResponse()
            },
            writeKeychain: { _ in true },
            writeFile: { _ in true },
            remember: { _ in },
            now: { self.now })

        let refreshed = await renewer.refresh()
        XCTAssertFalse(refreshed)
        XCTAssertNil(fetches.file, "a login with no refresh token must not reach the token endpoint")
    }

    func testAWriteBackFailureStillRemembersTheFreshBytes() async throws {
        let writes = RenewalWrites()
        let renewer = ClaudeCredentialRenewer(
            readKeychainRoot: { self.renewableRoot(refreshToken: "keychain-refresh") },
            readFileRoot: { [:] },
            fetch: { _ in self.grantResponse() },
            writeKeychain: { _ in false },
            writeFile: { _ in false },
            remember: { data in writes.recordRemembered(data) },
            now: { self.now })

        let refreshed = await renewer.refresh()
        XCTAssertTrue(refreshed)
        let remembered = try XCTUnwrap(writes.remembered)
        let root = try XCTUnwrap(ClaudeOAuthParser.parse(remembered))
        XCTAssertNotNil(ClaudeOAuthParser.validOAuth(in: root, now: now))
    }

    // MARK: - The credentials file store

    func testCredentialsFileWriteIsAtomicOwnerOnlyAndRoundTrips() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecaps-renewer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = renewableRoot(refreshToken: "file-refresh")
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        XCTAssertTrue(ClaudeCredentialRenewer.writeCredentialsFile(data, homeDirectory: home))
        let readBack = ClaudeCredentialRenewer.readCredentialsFile(homeDirectory: home)
        XCTAssertEqual(ClaudeOAuthRefresh.refreshToken(in: readBack), "file-refresh")
        let path = home.appendingPathComponent(".claude/.credentials.json").path
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)

        // A second write replaces the first rather than failing on it.
        let rotated = try JSONSerialization.data(withJSONObject: renewableRoot(refreshToken: "rotated-refresh"), options: [.sortedKeys])
        XCTAssertTrue(ClaudeCredentialRenewer.writeCredentialsFile(rotated, homeDirectory: home))
        let reread = ClaudeCredentialRenewer.readCredentialsFile(homeDirectory: home)
        XCTAssertEqual(ClaudeOAuthRefresh.refreshToken(in: reread), "rotated-refresh")
    }
}

/// Thread-safe capture for what a renewal wrote, remembered, or fetched.
private final class RenewalWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var keychainData: Data?
    private var fileData: Data?
    private var rememberedData: Data?

    func recordKeychain(_ data: Data) { lock.lock(); keychainData = data; lock.unlock() }
    func recordFile(_ data: Data) { lock.lock(); fileData = data; lock.unlock() }
    func recordRemembered(_ data: Data) { lock.lock(); rememberedData = data; lock.unlock() }

    var keychain: Data? { lock.lock(); defer { lock.unlock() }; return keychainData }
    var file: Data? { lock.lock(); defer { lock.unlock() }; return fileData }
    var remembered: Data? { lock.lock(); defer { lock.unlock() }; return rememberedData }
}
