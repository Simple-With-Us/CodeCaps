import Foundation

/// Reads Grok Bot's weekly included allowance from the local `gbu --json` CLI
/// (Kargatharaakash/grok-bot-usage).
///
/// This is an EXTRA source beside `GrokBotQuotaReader` (Cursor DashboardService).
/// Windows carry `source: "gbu"` so CodeCaps Settings can rank or disable them
/// independently.  Credentials live in `~/.gbu/`; this reader never prints them.
public struct GbuQuotaReader: Sendable {
    private let homeDirectory: URL
    private let now: @Sendable () -> Date
    private let runGbu: @Sendable () async throws -> Data

    private static let maxBytes = 1_048_576
    private static let timeout: TimeInterval = 20

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        runGbu: (@Sendable () async throws -> Data)? = nil
    ) {
        let home = homeDirectory.standardizedFileURL
        self.homeDirectory = home
        self.now = now
        self.runGbu = runGbu ?? {
            guard let bin = Self.findGbuBin(home: home) else {
                throw GbuQuotaError.notInstalled
            }
            return try await BoundedQuotaProcess().run(
                path: bin,
                arguments: ["--json"],
                home: home,
                timeout: Self.timeout,
                maxBytes: Self.maxBytes
            )
        }
    }

    public func read() async -> LocalQuotaResult {
        do {
            let data = try await runGbu()
            guard data.count <= Self.maxBytes,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any] else {
                return LocalQuotaResult(issues: ["gbu": "gbu returned no readable quota JSON."])
            }
            let accounts = (root["accounts"] as? [[String: Any]]) ?? []
            let active = gbuSafeString(root["active"])
            let observed = now()
            var windows: [QuotaWindow] = []
            for account in accounts {
                if let error = gbuSafeString(account["error"]), !error.isEmpty { continue }
                guard let window = gbuWindow(account, active: active, sole: accounts.count == 1, observedAt: observed) else {
                    continue
                }
                windows.append(window)
            }
            if windows.isEmpty {
                return LocalQuotaResult(
                    windows: [gbuUnknownWindow(observedAt: observed)],
                    issues: ["gbu": "gbu returned no readable Grok Bot weekly quota."]
                )
            }
            return LocalQuotaResult(windows: windows)
        } catch is CancellationError {
            return LocalQuotaResult(issues: ["gbu": "gbu quota refresh was cancelled."])
        } catch GbuQuotaError.notInstalled {
            // Optional EXTRA source: missing binary is silence, not a grok-bot issue.
            return LocalQuotaResult()
        } catch {
            return LocalQuotaResult(issues: ["gbu": "gbu quota source is unavailable."])
        }
    }

    fileprivate static func findGbuBin(home: URL, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String? {
        let candidates = [
            home.appendingPathComponent(".gbu/bin/gbu").path,
            home.appendingPathComponent(".local/bin/gbu").path,
            "/opt/homebrew/bin/gbu",
            "/usr/local/bin/gbu",
        ]
        return candidates.first(where: fileExists)
    }
}

private enum GbuQuotaError: Error {
    case notInstalled
}

private func gbuWindow(_ account: [String: Any], active: String?, sole: Bool, observedAt: Date) -> QuotaWindow? {
    guard let used = gbuNumber(account["weeklyUsagePercent"] ?? account["weekly_usage_percent"]),
          used.isFinite,
          used >= 0 else { return nil }

    let boundedUsed = min(100, max(0, used))
    // Match Usage-Monitor clampPercent: two decimal places.
    let remaining = ((100 - boundedUsed) * 100).rounded() / 100
    let reset = gbuTimestamp(account["resetsAt"] ?? account["resets_at"])
    let plan = gbuSafeString(account["planLabel"] ?? account["plan_label"])
    let email = gbuSafeString(account["email"] ?? account["account"])
    let accountName = gbuSafeString(account["account"] ?? account["email"]) ?? "account"
    let isActive = account["active"] as? Bool == true
        || (active.map { $0 == accountName || $0 == email } ?? false)
    let bucket = (isActive || sole) ? "gbu-weekly" : "gbu-weekly:\(accountName)"
    let label = (isActive || sole) ? "Grok Bot weekly" : "Grok Bot weekly (\(accountName))"
    let available = account["available"] as? Bool
    let exhausted = available == false || remaining == 0
    let includedRemaining = gbuNumber(account["includedRemaining"] ?? account["included_remaining"])
    let includedLimit = gbuNumber(account["includedLimit"] ?? account["included_limit"])

    return QuotaWindow(
        id: "local-mac:grok-bot:\(bucket)",
        provider: "Grok Bot",
        providerKey: "grok-bot",
        providerLabel: "Grok Bot",
        via: "gbu",
        sourceApp: "local-mac",
        label: label,
        remainingPercent: remaining,
        absoluteRemaining: includedRemaining,
        absoluteLimit: includedLimit,
        quotaUnit: includedLimit == nil ? nil : "credits",
        planName: plan,
        remainingUnknown: false,
        isExhausted: exhausted,
        resetAt: reset,
        window: "weekly",
        status: QuotaWindowStatus.derived(remainingPercent: remaining),
        skip: exhausted,
        skipReason: exhausted ? "quota exhausted" : nil,
        occurredAt: gbuISOFormatter.string(from: observedAt),
        source: "gbu"
    ).normalizedForExport()
}

private func gbuUnknownWindow(observedAt: Date) -> QuotaWindow {
    QuotaWindow(
        id: "local-mac:grok-bot:gbu-unknown",
        provider: "Grok Bot",
        providerKey: "grok-bot",
        providerLabel: "Grok Bot",
        via: "gbu",
        sourceApp: "local-mac",
        label: "Grok Bot weekly",
        remainingUnknown: true,
        status: .unknown,
        occurredAt: gbuISOFormatter.string(from: observedAt),
        source: "gbu"
    )
}

private func gbuNumber(_ value: Any?) -> Double? {
    if let number = value as? NSNumber,
       CFGetTypeID(number) != CFBooleanGetTypeID(),
       number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String,
       string.utf8.count <= 64,
       let number = Double(string),
       number.isFinite { return number }
    return nil
}

private func gbuSafeString(_ value: Any?) -> String? {
    guard let string = value as? String,
          string.utf8.count <= 256,
          !string.contains("\r"),
          !string.contains("\n") else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func gbuTimestamp(_ value: Any?) -> String? {
    if let string = value as? String {
        guard string.utf8.count <= 128 else { return nil }
        if let date = gbuDateFormatter.date(from: string) ?? gbuFractionalDateFormatter.date(from: string) {
            return gbuISOFormatter.string(from: date)
        }
        if let seconds = Double(string), seconds.isFinite { return gbuTimestamp(seconds) }
        return nil
    }
    if let number = gbuNumber(value) {
        let seconds = abs(number) > 10_000_000_000 ? number / 1_000 : number
        guard number.isFinite, seconds.isFinite, abs(seconds) <= 4_102_444_800 else { return nil }
        return gbuISOFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }
    return nil
}

private let gbuDateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
private let gbuFractionalDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let gbuISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
