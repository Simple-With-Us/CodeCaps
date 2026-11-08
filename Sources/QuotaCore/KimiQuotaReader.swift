import Foundation

/// Reads Kimi Code's subscription quota over HTTPS using the local Kimi CLI
/// sign-in.  The CLI owns the OAuth login; this reader only consumes the
/// access token the CLI already wrote to `~/.kimi-code/credentials/` (or the
/// `~/.kimi/credentials/` layout of the community CLI) and never persists,
/// logs, or refreshes it.  Token contents never leave this type.
public struct KimiQuotaReader: Sendable {
    private let now: @Sendable () -> Date
    private let credential: @Sendable () -> (token: String?, expiresAt: Date?)
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let maxResponseBytes = 262_144
    private static let maxCredentialBytes = 65_536
    private static let timeout: TimeInterval = 15

    /// Kimi Code's documented bases: the default China host and the overseas
    /// host the public docs list side by side.  A US install can land on
    /// either, so a non-successful answer from the first host is retried
    /// against the second before anything is reported.
    private static let usageURLs = [
        URL(string: "https://api.kimi.com/coding/v1/usages")!,
        URL(string: "https://api.kimi.ai/coding/v1/usages")!,
    ]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        accessToken: (@Sendable () -> String?)? = nil,
        credentialExpiresAt: (@Sendable () -> Date?)? = nil,
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.now = now
        let home = homeDirectory.standardizedFileURL
        if let accessToken {
            if let credentialExpiresAt {
                self.credential = { (accessToken(), credentialExpiresAt()) }
            } else {
                self.credential = { (accessToken(), nil) }
            }
        } else {
            // One store read per refresh: the token and its expiry must come
            // from the same snapshot, or a credential the CLI rewrites
            // mid-refresh pairs a rejected token with the wrong expiry.
            self.credential = {
                guard let local = Self.readLocalCredential(home: home) else { return (nil, nil) }
                return (local.token, local.expiresAt)
            }
        }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    public func read() async -> LocalQuotaResult {
        do {
            let snapshot = credential()
            guard let token = snapshot.token, !token.isEmpty else {
                // No local sign-in at all: the product is simply absent, the
                // same way a missing `gh` binary is not a Copilot error.
                return LocalQuotaResult()
            }
            var lastStatus = 0
            var sawTransportError = false
            for url in Self.usageURLs {
                try Task.checkCancellation()
                let result: KimiHTTPPayload
                do {
                    result = try await Self.fetchUsage(url: url, token: token, fetch: fetch)
                } catch is CancellationError {
                    // Cooperative cancellation is not a transport failure;
                    // rethrow so the outer catch reports the cancellation.
                    throw CancellationError()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    // One unreachable host must not mask a healthy second one.
                    sawTransportError = true
                    continue
                }
                lastStatus = result.statusCode
                if result.statusCode == 401 || result.statusCode == 403 {
                    continue // try the other documented host before blaming the login
                }
                guard (200..<300).contains(result.statusCode), let root = result.root else {
                    continue
                }
                // A signed-in account with no Kimi Code plan answers 200 with
                // an empty object (seen live, 2026-11-06).  There is nothing
                // to monitor, so the product is absent, the same way a missing
                // sign-in is, rather than a quota CodeCaps failed to read.
                if root.isEmpty { return LocalQuotaResult() }
                let windows = Self.parse(root, observedAt: now())
                if windows.isEmpty {
                    return LocalQuotaResult(issues: ["kimi": "Kimi returned no readable quota."])
                }
                let issues = windows.allSatisfy { $0.remainingPercent == nil }
                    ? ["kimi": "Kimi returned no readable quota."]
                    : [:]
                return LocalQuotaResult(windows: windows, issues: issues)
            }
            if lastStatus == 401 || lastStatus == 403 {
                // A token the credential file itself marks expired is a
                // routine refresh wait, not a dead sign-in: the CLI refreshes
                // it on its next use and this reader then reads the fresh
                // file.  Only a rejection with no local expiry evidence is
                // worded as a sign-in problem.  The expiry is the one taken
                // alongside the token, never a second store read.
                if let expiry = snapshot.expiresAt, now() >= expiry {
                    return LocalQuotaResult(issues: ["kimi": "Kimi's stored access token has expired; open Kimi Code to refresh it."])
                }
                return LocalQuotaResult(issues: ["kimi": "Kimi session was rejected; sign in again in Kimi Code."])
            }
            return LocalQuotaResult(issues: ["kimi": sawTransportError
                ? "Kimi quota service could not be reached."
                : "Kimi quota service is unavailable."])
        } catch is CancellationError {
            return LocalQuotaResult(issues: ["kimi": "Kimi quota refresh was cancelled."])
        } catch {
            return LocalQuotaResult(issues: ["kimi": "Kimi quota service is unavailable."])
        }
    }
}

private struct KimiHTTPPayload {
    let statusCode: Int
    let root: [String: Any]?
}

private extension KimiQuotaReader {
    static func fetchUsage(
        url: URL,
        token: String,
        fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> KimiHTTPPayload {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        let root = data.count <= Self.maxResponseBytes
            ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            : nil
        return KimiHTTPPayload(statusCode: response.statusCode, root: root)
    }

    /// Parses the `{usage, limits[]}` payload the CLI's own `/usage` command
    /// renders (kimi-cli `ui/shell/usage.py`): a summary row plus per-limit
    /// detail rows with a rolling-window descriptor.
    static func parse(_ root: [String: Any], observedAt: Date) -> [QuotaWindow] {
        let observed = ISO8601DateFormatter().string(from: observedAt)
        var windows: [QuotaWindow] = []
        if let usage = root["usage"] as? [String: Any],
           let window = rowWindow(usage, id: "local-mac:kimi:summary", defaultLabel: "Weekly limit", observed: observed) {
            windows.append(window)
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() {
                let detail = item["detail"] as? [String: Any] ?? item
                let windowInfo = item["window"] as? [String: Any] ?? [:]
                let label = limitLabel(item: item, detail: detail, window: windowInfo, index: index)
                let windowName = windowLabel(window: windowInfo, item: item, detail: detail)
                if let window = rowWindow(detail, id: "local-mac:kimi:limit-\(index)", defaultLabel: label,
                                          windowName: windowName, observed: observed) {
                    windows.append(window)
                }
            }
        }
        return windows
    }

    static func rowWindow(
        _ data: [String: Any],
        id: String,
        defaultLabel: String,
        windowName: String? = nil,
        observed: String
    ) -> QuotaWindow? {
        let limit = number(data["limit"])
        var used = number(data["used"])
        let remainingField = number(data["remaining"])
        if used == nil, let remainingField, let limit { used = limit - remainingField }
        guard used != nil || limit != nil else { return nil }
        let label = string(data["name"]) ?? string(data["title"]) ?? defaultLabel
        let remaining = remainingField ?? (limit.flatMap { l in used.map { max(0, l - $0) } })
        let percent: Double?
        if let limit, limit > 0, let remaining {
            percent = min(100, max(0, remaining / limit * 100))
        } else {
            percent = nil
        }
        let exhausted = percent == 0
        return QuotaWindow(
            id: id, provider: "Kimi", providerKey: "kimi", providerLabel: "Kimi",
            sourceApp: "local-mac", label: label,
            remainingPercent: percent,
            absoluteRemaining: remaining, absoluteLimit: limit,
            quotaUnit: nil,
            remainingUnknown: percent == nil,
            isExhausted: exhausted,
            resetAt: resetTimestamp(data),
            window: windowName,
            status: QuotaWindowStatus.derived(remainingPercent: percent),
            skip: exhausted, skipReason: exhausted ? "quota exhausted" : nil,
            occurredAt: observed, source: "kimi"
        )
    }

    /// The CLI's own labeling order: an explicit name/title/scope wins, then a
    /// readable rendering of the rolling window ("5h limit").
    static func limitLabel(item: [String: Any], detail: [String: Any], window: [String: Any], index: Int) -> String {
        for key in ["name", "title", "scope"] {
            if let value = string(item[key]) ?? string(detail[key]) { return value }
        }
        if let duration = int(window["duration"]) ?? int(item["duration"]) ?? int(detail["duration"]) {
            let unit = (string(window["timeUnit"]) ?? string(item["timeUnit"]) ?? string(detail["timeUnit"]) ?? "").uppercased()
            if unit.contains("MINUTE") {
                if duration >= 60, duration % 60 == 0 { return "\(duration / 60)h limit" }
                return "\(duration)m limit"
            }
            if unit.contains("HOUR") { return "\(duration)h limit" }
            if unit.contains("DAY") { return "\(duration)d limit" }
            if unit.contains("WEEK") { return "\(duration)w limit" }
            return "\(duration)s limit"
        }
        return "Limit \(index + 1)"
    }

    static func windowLabel(window: [String: Any], item: [String: Any], detail: [String: Any]) -> String? {
        guard let duration = int(window["duration"]) ?? int(item["duration"]) ?? int(detail["duration"]) else { return nil }
        let unit = (string(window["timeUnit"]) ?? string(item["timeUnit"]) ?? string(detail["timeUnit"]) ?? "").uppercased()
        if unit.contains("DAY") { return duration >= 28 ? "monthly" : (duration >= 7 ? "weekly" : "daily") }
        if unit.contains("HOUR") { return "\(duration)h" }
        if unit.contains("MINUTE") { return duration >= 60 && duration % 60 == 0 ? "\(duration / 60)h" : "\(duration)m" }
        if unit.contains("WEEK") { return duration == 1 ? "weekly" : "\(duration)w" }
        return nil
    }

    static func resetTimestamp(_ data: [String: Any]) -> String? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            guard let text = string(data[key]), text.utf8.count <= 64 else { continue }
            let iso = ISO8601DateFormatter()
            if iso.date(from: text) != nil { return text }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if iso.date(from: text) != nil { return text }
        }
        return nil
    }

    /// Newest credential JSON under the two documented roots, then the
    /// `api_key` lines of `config.toml` / `config.json` as a last resort.
    internal static func readLocalAccessToken(
        home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        readLocalCredential(home: home, environment: environment)?.token
    }

    /// The token plus the expiry the credential records alongside it, so a
    /// server rejection can be told apart from a locally known expiry.
    internal static func readLocalCredential(
        home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (token: String, expiresAt: Date?)? {
        let roots = [
            environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".kimi-code"),
            environment["KIMI_SHARE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".kimi"),
        ]
        let manager = FileManager.default
        // Newest credential across BOTH roots: a fresh sign-in in the second
        // root must beat a stale file in the first.
        var candidates: [URL] = []
        for root in roots {
            let candidate = root.appendingPathComponent("credentials/kimi-code.json")
            if manager.fileExists(atPath: candidate.path) { candidates.append(candidate) }
        }
        candidates.sort { lhs, rhs in
            let l = (try? manager.attributesOfItem(atPath: lhs.path)[.modificationDate] as? Date) ?? nil
            let r = (try? manager.attributesOfItem(atPath: rhs.path)[.modificationDate] as? Date) ?? nil
            return (l ?? .distantPast) > (r ?? .distantPast)
        }
        for candidate in candidates {
            if let credential = credentialToken(at: candidate) { return credential }
        }
        for root in roots {
            if let token = configToken(root: root) { return (token, nil) }
        }
        return nil
    }

    static func credentialToken(at url: URL) -> (token: String, expiresAt: Date?)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= Self.maxCredentialBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Extract the raw string, NOT via the label-capped string() helper:
        // that helper caps at 160 bytes for display names, and a real OAuth
        // access token is routinely far longer - routing it through the cap
        // silently read a signed-in account as "no local sign-in".
        guard let token = root["access_token"] as? String, validToken(token) else { return nil }
        // A token whose recorded expiry has passed is only going to earn a
        // 401; the CLI refreshes it on next use, so report the stored one
        // anyway and let the server answer.
        return (token, credentialExpiry(root["expires_at"] ?? root["expiresAt"]))
    }

    /// The credential's own expiry: epoch seconds (the live file's form),
    /// epoch milliseconds, or an ISO-8601 stamp.
    internal static func credentialExpiry(_ value: Any?) -> Date? {
        if let number = number(value) {
            if number >= 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            return Date(timeIntervalSince1970: number)
        }
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 64 else { return nil }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)
    }

    internal static func configToken(root: URL) -> String? {
        if let data = try? Data(contentsOf: root.appendingPathComponent("config.toml"), options: .mappedIfSafe),
           data.count <= Self.maxCredentialBytes, let text = String(data: data, encoding: .utf8) {
            var providers: [(name: String, fields: [String: String])] = []
            var currentName: String?
            var fields: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") {
                    if let currentName { providers.append((currentName, fields)) }
                    currentName = providerTableName(trimmed)
                    fields = [:]
                    continue
                }
                guard currentName != nil, let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                guard ["type", "base_url", "api_key"].contains(key),
                      let value = tomlString(String(trimmed[trimmed.index(after: equals)...])) else { continue }
                fields[key] = value
            }
            if let currentName { providers.append((currentName, fields)) }
            for provider in providers {
                if let token = providerToken(name: provider.name, fields: provider.fields) { return token }
            }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("config.json"), options: .mappedIfSafe),
           data.count <= Self.maxCredentialBytes,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let providers = object["providers"] as? [String: Any] {
                for name in providers.keys.sorted() {
                    guard let provider = providers[name] as? [String: Any],
                          let token = providerToken(name: name, object: provider) else { continue }
                    return token
                }
            }
            // Legacy JSON must identify both the provider and its coding API base.
            if let token = providerToken(name: object["provider"] as? String ?? "", object: object) { return token }
        }
        return nil
    }

    private static func providerToken(name: String, object: [String: Any]) -> String? {
        var fields: [String: String] = [:]
        fields["type"] = object["type"] as? String
        fields["base_url"] = (object["base_url"] ?? object["baseUrl"]) as? String
        fields["api_key"] = (object["api_key"] ?? object["apiKey"]) as? String
        return providerToken(name: name, fields: fields)
    }

    private static func providerToken(name: String, fields: [String: String]) -> String? {
        let explicitlyKimi = ["managed:kimi-code", "kimi-code", "kimi"].contains(name) || fields["type"] == "kimi"
        guard explicitlyKimi, let base = fields["base_url"], approvedCodingBase(base),
              let token = fields["api_key"], validToken(token) else { return nil }
        return token
    }

    private static func approvedCodingBase(_ raw: String) -> Bool {
        guard let url = URLComponents(string: raw), url.scheme == "https",
              let host = url.host?.lowercased(), ["api.kimi.com", "api.kimi.ai"].contains(host),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        return ["/coding/v1", "/coding/v1/"].contains(url.percentEncodedPath)
    }

    /// A narrow TOML reader accepts only provider tables and quoted scalars.
    /// Unknown tables, multiline strings, and ambiguous syntax fail closed.
    private static func providerTableName(_ line: String) -> String? {
        let pattern = #"^\[\s*providers\s*\.\s*(?:"([^"\\]+)"|'([^']+)'|([A-Za-z0-9_-]+))\s*\]\s*(?:#.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: line) { return String(line[range]) }
        }
        return nil
    }

    private static func tomlString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        var escaped = false
        for index in value.indices.dropFirst() {
            let character = value[index]
            if quote == "\"", character == "\\", !escaped { escaped = true; continue }
            if character == quote, !escaped {
                let tail = value[value.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
                if quote == "'" { return String(value[value.index(after: value.startIndex)..<index]) }
                let encoded = String(value[...index])
                return try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
            }
            escaped = false
        }
        return nil
    }

    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 8_192 && !token.contains("\r") && !token.contains("\n")
    }

    static func makeFetcher() -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        return { request in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            let session = URLSession(configuration: config, delegate: KimiNoRedirectDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw KimiQuotaError.unavailable }
            if let length = http.value(forHTTPHeaderField: "Content-Length"), let count = Int(length), count > Self.maxResponseBytes {
                throw KimiQuotaError.unavailable
            }
            var data = Data()
            data.reserveCapacity(16_384)
            for try await byte in bytes {
                guard data.count < Self.maxResponseBytes else { throw KimiQuotaError.unavailable }
                data.append(byte)
            }
            return (data, http)
        }
    }

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 160 else { return nil }
        return text
    }

    /// A non-negative finite count.  Kimi's live `/usages` payload quotes its
    /// int64 counts (`"limit": "100"`), as protobuf JSON does, and the Kimi
    /// CLI's own parser reads them as strings too, so a plain decimal string
    /// counts.  Hex, exponent and signed forms do not.
    static func number(_ value: Any?) -> Double? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 32,
                  trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let parsed = Double(trimmed), parsed.isFinite else { return nil }
            return parsed
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    internal static func int(_ value: Any?) -> Int? {
        guard let number = number(value), number.isFinite,
              number >= Double(Int.min), number <= Double(Int.max),
              let exact = Int(exactly: number) else { return nil }
        return exact
    }
}

private enum KimiQuotaError: Error {
    case unavailable
}

private final class KimiNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
