import Foundation

/// The OAuth refresh grant Claude Code itself performs when its saved access
/// token has expired, packaged so CodeCaps can run it directly.
///
/// The older self-heal asked Claude Code to renew its own login with a
/// zero-turn print-mode `/usage` run, on the theory that starting a session
/// makes Claude Code refresh.  It does not: that run makes no API call, so
/// nothing ever reached the grant, and an expired login stayed expired until
/// an interactive Claude Code run happened to renew it — the Claude row sat
/// at "login idle" in the meantime.  Running the grant here — same endpoint,
/// same public client id, same record shape — renews the login in the
/// background.
///
/// Anthropic rotates the refresh token on every grant, so the refreshed
/// record is written back to the store it came from, and only that store:
/// a refreshed pair that is not persisted (or is persisted to the other
/// store) leaves the saved login holding a dead refresh token, and the next
/// renewal — Claude Code's or ours — fails.  The fresh bytes are also
/// remembered in process, so the current run's feed recovers even when a
/// write-back could not land.
///
/// Nothing here logs a token, puts one in a process argument, or sends one
/// anywhere but Anthropic's token endpoint.  The client id is Claude Code's
/// public installed-app identifier, shipped in every copy of the CLI; it is
/// not a secret.
public enum ClaudeOAuthRefresh {
    /// Where Claude Code exchanges its grants.
    public static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// Claude Code's public OAuth client id.
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// The refresh-grant request, in the shape Claude Code sends it.
    public static func refreshRequest(refreshToken: String) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        return request
    }

    /// The credential record after a successful grant, or nil when the
    /// response carries no usable access token.  Only the token fields move:
    /// every other field of the saved record (subscription type, account
    /// metadata, sibling keys) is preserved exactly, the new expiry is
    /// `now + expires_in` written as epoch milliseconds the way Claude Code
    /// writes it, and key spellings follow the record being updated, so a
    /// snake_case record stays snake_case.
    public static func refreshedRoot(existing root: [String: Any],
                                     response: [String: Any],
                                     now: Date) -> [String: Any]? {
        guard let accessToken = response["access_token"] as? String, !accessToken.isEmpty,
              let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue,
              expiresIn > 0, expiresIn.isFinite else {
            return nil
        }
        let expiresAt = NSNumber(value: Int64((now.timeIntervalSince1970 + expiresIn) * 1000))
        func updated(_ record: [String: Any]) -> [String: Any] {
            var record = record
            let snake = record["access_token"] != nil
            record[snake ? "access_token" : "accessToken"] = accessToken
            if let refreshToken = response["refresh_token"] as? String, !refreshToken.isEmpty {
                record[snake ? "refresh_token" : "refreshToken"] = refreshToken
            }
            record[snake ? "expires_at" : "expiresAt"] = expiresAt
            if let scope = response["scope"] as? String, !scope.isEmpty {
                record["scopes"] = scope.split(separator: " ").map(String.init)
            }
            if let refreshExpiresIn = (response["refresh_token_expires_in"] as? NSNumber)?.doubleValue,
               refreshExpiresIn > 0, refreshExpiresIn.isFinite {
                let refreshExpiresAt = NSNumber(value: Int64((now.timeIntervalSince1970 + refreshExpiresIn) * 1000))
                record[snake ? "refresh_token_expires_at" : "refreshTokenExpiresAt"] = refreshExpiresAt
            }
            return record
        }
        var root = root
        if let nested = root["claudeAiOauth"] as? [String: Any] {
            root["claudeAiOauth"] = updated(nested)
            return root
        }
        return updated(root)
    }

    /// The OAuth record inside a credentials root, in the shape the parser
    /// reads: nested under `claudeAiOauth` when present, else the root itself.
    static func record(in root: [String: Any]) -> [String: Any] {
        root["claudeAiOauth"] as? [String: Any] ?? root
    }

    /// The record's refresh token, or nil when it has none worth sending.
    static func refreshToken(in root: [String: Any]) -> String? {
        let record = record(in: root)
        for key in ["refreshToken", "refresh_token"] {
            if let value = record[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}

/// One direct renewal of Claude Code's saved login, with every collaborator
/// injected so tests exercise the whole flow — store choice, grant, write-
/// back, remembering — without a network, a Keychain, or a disk.  Production
/// uses `live(homeDirectory:)`.
public struct ClaudeCredentialRenewer: Sendable {
    /// Which store a renewable login came from.  The refreshed record is
    /// written back to that store and no other.
    enum Store: Sendable {
        case keychain
        case file
    }

    var readKeychainRoot: @Sendable () async -> [String: Any]
    var readFileRoot: @Sendable () -> [String: Any]
    var fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    var writeKeychain: @Sendable (Data) async -> Bool
    var writeFile: @Sendable (Data) -> Bool
    var remember: @Sendable (Data) -> Void
    var now: @Sendable () -> Date

    public init(readKeychainRoot: @escaping @Sendable () async -> [String: Any],
                readFileRoot: @escaping @Sendable () -> [String: Any],
                fetch: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
                writeKeychain: @escaping @Sendable (Data) async -> Bool,
                writeFile: @escaping @Sendable (Data) -> Bool,
                remember: @escaping @Sendable (Data) -> Void,
                now: @escaping @Sendable () -> Date) {
        self.readKeychainRoot = readKeychainRoot
        self.readFileRoot = readFileRoot
        self.fetch = fetch
        self.writeKeychain = writeKeychain
        self.writeFile = writeFile
        self.remember = remember
        self.now = now
    }

    /// Attempts one direct renewal, store by store.  The Keychain is tried
    /// first: on a Mac it is the store Claude Code keeps current, while the
    /// credentials file may be a leftover whose refresh token rotated away
    /// long ago.  A refused grant in either store falls through to the
    /// other; only a success stops the search.
    ///
    /// Returns true when a grant succeeded.  The refreshed bytes are
    /// remembered for this process whether or not the write-back landed, so
    /// the current run's feed recovers either way.  Returns false when no
    /// saved login could be renewed directly — no refresh token on this Mac,
    /// every grant refused, or the network failed — leaving the caller to
    /// fall back to asking Claude Code itself.
    public func refresh() async -> Bool {
        let now = now()
        let candidates: [(Store, [String: Any])] = [
            (.keychain, await readKeychainRoot()),
            (.file, readFileRoot()),
        ]
        for (store, root) in candidates {
            guard ClaudeOAuthParser.canRenewAfterUsageRejection(in: root, now: now),
                  let refreshToken = ClaudeOAuthRefresh.refreshToken(in: root) else { continue }
            guard let refreshed = await grant(refreshToken: refreshToken, existing: root, now: now) else { continue }
            switch store {
            case .keychain: _ = await writeKeychain(refreshed)
            case .file: _ = writeFile(refreshed)
            }
            remember(refreshed)
            return true
        }
        return false
    }

    /// One grant against the token endpoint.  The response body is decoded
    /// and discarded; nothing from it is logged or retained beyond the
    /// refreshed record built from it.
    private func grant(refreshToken: String, existing root: [String: Any], now: Date) async -> Data? {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetch(ClaudeOAuthRefresh.refreshRequest(refreshToken: refreshToken))
        } catch {
            return nil
        }
        guard response.statusCode == 200,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let updated = ClaudeOAuthRefresh.refreshedRoot(existing: root, response: payload, now: now) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
    }
}

extension ClaudeCredentialRenewer {
    /// The production renewer: the real Keychain read, the credentials file,
    /// the bounded HTTPS transport, and write-back through the same channels
    /// the reads use — the `security` tool for the Keychain item, an atomic
    /// 0600 replace for the file.
    static func live(homeDirectory: URL) -> ClaudeCredentialRenewer {
        ClaudeCredentialRenewer(
            readKeychainRoot: {
                let access = await ClaudeCredentialSource.access()
                guard let data = access.data else { return [:] }
                return ClaudeOAuthParser.parse(data) ?? [:]
            },
            readFileRoot: { readCredentialsFile(homeDirectory: homeDirectory) },
            fetch: { request in
                try await BoundedHTTPFetch.data(for: request, timeout: 15, maxBytes: 1_048_576)
            },
            writeKeychain: { data in await ClaudeCredentialSource.updateSavedLogin(data) },
            writeFile: { data in writeCredentialsFile(data, homeDirectory: homeDirectory) },
            remember: { data in
                ClaudeCredentialSource.remember(data)
            },
            now: { Date() })
    }

    /// Claude Code's on-disk credential store.  The parser's 1 MB cap is
    /// enforced on the file's size before its bytes are loaded, so an
    /// oversized file is never fully allocated here.
    static func readCredentialsFile(homeDirectory: URL) -> [String: Any] {
        let url = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attributes[.size] as? NSNumber)?.int64Value, size > 1_048_576 { return [:] }
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return ClaudeOAuthParser.parse(data) ?? [:]
    }

    /// Replaces the credentials file with `data`, atomically and at owner-
    /// only permissions: the new bytes are staged beside the target, set to
    /// 0600 while still staged, then moved over the old file, so no reader
    /// can ever catch a torn credential.  `replaceItemAt` keeps the replaced
    /// file's permissions, so 0600 is re-applied to the file now in place —
    /// a pre-existing world-readable credentials file does not stay that way.
    static func writeCredentialsFile(_ data: Data, homeDirectory: URL) -> Bool {
        let directory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let target = directory.appendingPathComponent(".credentials.json")
        let staging = directory.appendingPathComponent(".credentials.json.codecaps-\(UUID().uuidString)")
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: staging)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            try? fileManager.removeItem(at: staging)
            return false
        }
    }
}
