import CoreFoundation
import Foundation

/// Reads Copilot's structured quota response using the existing GitHub CLI login.
/// The CLI owns credential access; tokens and diagnostic output never enter this reader.
public struct CopilotQuotaReader: Sendable {
    private let now: @Sendable () -> Date
    private let runCopilot: @Sendable () async throws -> Data
    private static let maxBytes = 262_144

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        runCopilot: (@Sendable () async throws -> Data)? = nil
    ) {
        self.now = now
        let home = homeDirectory.standardizedFileURL
        self.runCopilot = runCopilot ?? {
            let paths = [home.appendingPathComponent(".local/bin/gh").path,
                         "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw CopilotReadError.notInstalled
            }
            return try await BoundedQuotaProcess().run(
                path: path,
                arguments: ["api", "--hostname", "github.com", "/copilot_internal/user",
                            "-H", "Accept: application/json", "-H", "User-Agent: CodeCaps"],
                home: home, timeout: 20, maxBytes: Self.maxBytes
            )
        }
    }

    public func read() async -> LocalQuotaResult {
        do {
            let data = try await runCopilot()
            guard data.count <= Self.maxBytes,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return failure("Copilot returned no readable quota JSON.")
            }
            let plan = Self.plan(root["copilot_plan"])
            let reset = Self.timestamp(root["quota_reset_date"])
            let observed = ISO8601DateFormatter().string(from: now())
            let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
            // Fixed API bucket names prevent response text from becoming exported identifiers.
            let buckets = [("premium_interactions", "Premium requests"),
                           ("chat", "Chat requests"), ("completions", "Completions")]
            var windows: [QuotaWindow] = []
            for (key, label) in buckets {
                guard let quota = snapshots[key] as? [String: Any] else { continue }
                let unlimited = quota["unlimited"] as? Bool == true
                let limit = unlimited ? nil : Self.number(quota["entitlement"])
                let remaining = unlimited ? nil : Self.number(quota["remaining"])
                let reported = unlimited ? nil : Self.number(quota["percent_remaining"])
                let percent: Double?
                if let reported { percent = min(100, reported) }
                else if let limit, limit > 0, let remaining { percent = min(100, remaining / limit * 100) }
                else { percent = nil }
                let exhausted = !unlimited && (remaining == 0 || percent == 0)
                windows.append(QuotaWindow(
                    id: "local-mac:github-copilot:\(key)", provider: "GitHub Copilot",
                    providerKey: "github-copilot", providerLabel: "GitHub Copilot", via: "gh",
                    sourceApp: "local-mac", label: unlimited ? "\(label) (unlimited)" : label,
                    remainingPercent: percent, absoluteRemaining: remaining, absoluteLimit: limit,
                    quotaUnit: unlimited ? nil : "requests", planName: plan,
                    remainingUnknown: percent == nil, isExhausted: exhausted,
                    resetAt: Self.timestamp(quota["quota_reset_date"]) ?? reset, window: "monthly",
                    status: percent.map { QuotaWindowStatus.derived(remainingPercent: $0) } ?? .unknown,
                    skip: exhausted, skipReason: exhausted ? "quota exhausted" : nil,
                    occurredAt: observed, source: "copilot"
                ))
            }
            if windows.isEmpty {
                guard plan != nil || reset != nil else { return failure("Copilot returned no readable plan or quota.") }
                windows = [QuotaWindow(
                    id: "local-mac:github-copilot:plan", provider: "GitHub Copilot",
                    providerKey: "github-copilot", providerLabel: "GitHub Copilot", via: "gh",
                    sourceApp: "local-mac", label: "Copilot plan", planName: plan,
                    remainingUnknown: true, resetAt: reset, window: "monthly", status: .unknown,
                    occurredAt: observed, source: "copilot"
                )]
            }
            return LocalQuotaResult(windows: windows)
        } catch CopilotReadError.notInstalled {
            return LocalQuotaResult()
        } catch is CancellationError {
            return failure("Copilot quota refresh was cancelled.")
        } catch {
            return failure("Copilot quota source is unavailable; check the existing GitHub CLI sign-in.")
        }
    }

    private func failure(_ message: String) -> LocalQuotaResult {
        LocalQuotaResult(issues: ["github-copilot": message])
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    private static func plan(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 80,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _+-")).contains($0) }) else { return nil }
        return text
    }

    private static func timestamp(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 64 else { return nil }
        let iso = ISO8601DateFormatter()
        var date = iso.date(from: text)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text)
        }
        if date == nil, text.count == 10 {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(secondsFromGMT: 0)
            day.dateFormat = "yyyy-MM-dd"
            day.isLenient = false
            date = day.date(from: text)
        }
        return date.map { ISO8601DateFormatter().string(from: $0) }
    }
}

private enum CopilotReadError: Error { case notInstalled }
