import Foundation

/// Reads OpenCode Go's subscription quota from OpenCode's documented usage
/// endpoint (`GET https://opencode.ai/inference/go/v1/usage`) using the Go
/// key the OpenCode CLI already saved in its local auth file.
///
/// The key is read read-only from `~/.local/share/opencode/auth.json`
/// (`$XDG_DATA_HOME/opencode/auth.json` when set), never persisted, logged,
/// or refreshed by this reader.  A missing auth file or a missing Go entry
/// means the product is simply absent, the same way a missing `gh` binary is
/// not a Copilot error.  `opencode stats` and the local database are
/// consumption estimates, not remaining quota, and are never read here.
public struct OpenCodeGoQuotaReader: Sendable {
    public static let providerKey = "opencode-go"
    public static let usageURL = URL(string: "https://opencode.ai/inference/go/v1/usage")!

    private let now: @Sendable () -> Date
    private let credential: @Sendable () -> String?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let maxResponseBytes = 262_144
    private static let maxCredentialBytes = 1_048_576
    private static let timeout: TimeInterval = 15

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        accessToken: (@Sendable () -> String?)? = nil,
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.now = now
        if let accessToken {
            self.credential = accessToken
        } else {
            let home = homeDirectory.standardizedFileURL
            self.credential = { Self.readGoKey(home: home, environment: environment) }
        }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    public func read() async -> LocalQuotaResult {
        let id = Self.providerKey
        do {
            guard let key = credential(), !key.isEmpty else {
                // No local OpenCode Go sign-in: the product is absent.
                return LocalQuotaResult()
            }
            var request = URLRequest(url: Self.usageURL)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = Self.timeout
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            if response.statusCode == 401 {
                return LocalQuotaResult(issues: [id: "OpenCode Go rejected the saved key; sign in again in OpenCode."])
            }
            if response.statusCode == 403 {
                return LocalQuotaResult(issues: [id: "OpenCode Go reports no active Go subscription for this key."])
            }
            guard (200..<300).contains(response.statusCode) else {
                return LocalQuotaResult(issues: [id: "OpenCode Go quota service is unavailable."])
            }
            guard data.count <= Self.maxResponseBytes,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return LocalQuotaResult(issues: [id: "OpenCode Go returned no readable quota."])
            }
            let windows = Self.parse(root, observedAt: now())
            if windows.isEmpty {
                return LocalQuotaResult(issues: [id: "OpenCode Go returned no readable quota."])
            }
            return LocalQuotaResult(windows: windows)
        } catch is CancellationError {
            return LocalQuotaResult(issues: [id: "OpenCode Go quota refresh was cancelled."])
        } catch {
            if Task.isCancelled { return LocalQuotaResult(issues: [id: "OpenCode Go quota refresh was cancelled."]) }
            return LocalQuotaResult(issues: [id: "OpenCode Go quota service could not be reached."])
        }
    }

    /// Parses `usage.{rolling,weekly,monthly}.{status,percent,resetsAt}`.
    /// `percent` is the share already used, so the remaining share CodeCaps
    /// displays is its complement.  The same shape at the top level (without
    /// the `usage` wrapper) is accepted so a documented-shape change in one
    /// place does not silently drop every window.
    static func parse(_ root: [String: Any], observedAt: Date) -> [QuotaWindow] {
        let usage = (root["usage"] as? [String: Any]) ?? root
        let observed = ISO8601DateFormatter().string(from: observedAt)
        let kinds: [(key: String, label: String, window: String)] = [
            ("rolling", "5 hours", "5h"),
            ("weekly", "Weekly", "weekly"),
            ("monthly", "Monthly", "monthly"),
        ]
        return kinds.compactMap { kind in
            guard let entry = usage[kind.key] as? [String: Any],
                  let used = number(entry["percent"]), (0...100).contains(used) else { return nil }
            let remaining = 100 - used
            let statusText = (entry["status"] as? String)?.lowercased()
            let exhausted = remaining == 0 || statusText == "rate-limited" || statusText == "rate_limited"
            return QuotaWindow(
                id: "opencode-go:" + kind.key, provider: Self.providerKey, providerKey: Self.providerKey,
                providerLabel: "OpenCode Go", label: kind.label, remainingPercent: remaining,
                isExhausted: exhausted, resetAt: resetTimestamp(entry),
                window: kind.window, status: .derived(remainingPercent: remaining),
                occurredAt: observed, source: "opencode-go-api")
        }
    }

    /// The Go entry of the CLI's auth file.  Entry field names are read
    /// tolerantly (`key`, then `apiKey`, then `access_token`) because the
    /// file is the CLI's private store; anything else is treated as absent
    /// rather than guessed at.  The raw string is extracted directly, never
    /// through a display-length-capped helper.
    internal static func readGoKey(
        home: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/share")
        let url = dataHome.appendingPathComponent("opencode/auth.json")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maxCredentialBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for entryKey in ["opencode-go", "opencode_go", "opencodeGo"] {
            guard let entry = root[entryKey] as? [String: Any] else { continue }
            // An OAuth entry carries no reusable API key for this endpoint.
            if let type = entry["type"] as? String, type.lowercased() == "oauth" { continue }
            for field in ["key", "apiKey", "api_key", "access_token", "accessToken"] {
                if let key = entry[field] as? String, validKey(key) { return key }
            }
        }
        return nil
    }

    static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 8_192 && !key.contains("\r") && !key.contains("\n")
    }

    private static func resetTimestamp(_ entry: [String: Any]) -> String? {
        for field in ["resetsAt", "resetAt", "resets_at", "reset_at"] {
            guard let text = entry[field] as? String, text.utf8.count <= 64 else { continue }
            let iso = ISO8601DateFormatter()
            if iso.date(from: text) != nil { return text }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if iso.date(from: text) != nil { return text }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 32,
                  trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let parsed = Double(trimmed), parsed.isFinite else { return nil }
            return parsed
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    static func makeFetcher() -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        return { request in
            let (data, response) = try await BoundedHTTPFetch.data(
                for: request, timeout: Self.timeout, maxBytes: Self.maxResponseBytes)
            return (data, response)
        }
    }
}
