import Foundation

/// Reads Kimi Code's subscription quota over HTTPS using the local Kimi CLI
/// sign-in.  The CLI owns the OAuth login; this reader only consumes the
/// access token the CLI already wrote to `~/.kimi-code/credentials/` (or the
/// `~/.kimi/credentials/` layout of the community CLI) and never persists,
/// logs, or refreshes it.  Token contents never leave this type.
public struct KimiQuotaReader: Sendable {
    private let now: @Sendable () -> Date
    private let accessToken: @Sendable () -> String?
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
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.now = now
        let home = homeDirectory.standardizedFileURL
        self.accessToken = accessToken ?? { Self.readLocalAccessToken(home: home) }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    public func read() async -> LocalQuotaResult {
        do {
            guard let token = accessToken(), !token.isEmpty else {
                // No local sign-in at all: the product is simply absent, the
                // same way a missing `gh` binary is not a Copilot error.
                return LocalQuotaResult()
            }
            var lastStatus = 0
            var sawTransportError = false
            for url in Self.usageURLs {
                let result: KimiHTTPPayload
                do {
                    result = try await Self.fetchUsage(url: url, token: token, fetch: fetch)
                } catch is CancellationError {
                    // Cooperative cancellation is not a transport failure;
                    // rethrow so the outer catch reports the cancellation.
                    throw CancellationError()
                } catch {
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
            quotaUnit: "requests",
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
    internal static func readLocalAccessToken(home: URL) -> String? {
        let roots = [
            ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".kimi-code"),
            ProcessInfo.processInfo.environment["KIMI_SHARE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".kimi"),
        ]
        let manager = FileManager.default
        // Newest credential across BOTH roots: a fresh sign-in in the second
        // root must beat a stale file in the first.
        var candidates: [URL] = []
        for root in roots {
            let directory = root.appendingPathComponent("credentials")
            if let names = try? manager.contentsOfDirectory(atPath: directory.path) {
                candidates += names.filter { $0.hasSuffix(".json") }
                    .map { directory.appendingPathComponent($0) }
            }
        }
        candidates.sort { lhs, rhs in
            let l = (try? manager.attributesOfItem(atPath: lhs.path)[.modificationDate] as? Date) ?? nil
            let r = (try? manager.attributesOfItem(atPath: rhs.path)[.modificationDate] as? Date) ?? nil
            return (l ?? .distantPast) > (r ?? .distantPast)
        }
        for candidate in candidates {
            if let token = credentialToken(at: candidate) { return token }
        }
        for root in roots {
            if let token = configToken(root: root) { return token }
        }
        return nil
    }

    static func credentialToken(at url: URL) -> String? {
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
        return token
    }

    internal static func configToken(root: URL) -> String? {
        if let data = try? Data(contentsOf: root.appendingPathComponent("config.toml"), options: .mappedIfSafe),
           data.count <= Self.maxCredentialBytes,
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces)
                guard key == "api_key" else { continue }
                let raw = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                // Quoted values keep everything to their closing quote;
                // bare values end at an inline `#` comment.
                let value: String
                if raw.hasPrefix("\""), let close = raw.dropFirst().firstIndex(of: "\"") {
                    value = String(raw.dropFirst()[..<close])
                } else if raw.hasPrefix("'"), let close = raw.dropFirst().firstIndex(of: "'") {
                    value = String(raw.dropFirst()[..<close])
                } else {
                    value = raw.split(separator: "#", maxSplits: 1).first
                        .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                }
                if validToken(value) { return value }
            }
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("config.json"), options: .mappedIfSafe),
           data.count <= Self.maxCredentialBytes,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = string(object["api_key"]) ?? string(object["apiKey"]), validToken(token) {
            return token
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

    static func number(_ value: Any?) -> Double? {
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
