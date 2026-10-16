import Foundation

/// Stable `bucketId` and `quotaWindow` values for Usage Monitor v2 ingest.
///
/// Mirrors `scripts/lib/subscription-quota-parsers.mjs` in the Usage-Monitor
/// repo so CodeCaps pushes land in the same buckets as the Mac collectors.
public enum UsageMonitorPushMetadata {
    public static func bucketId(for window: QuotaWindow) -> String {
        if let mapped = localMacBucketId(window) { return mapped }
        return fallbackBucketId(window)
    }

    /// The collector's `quotaWindow` token (`5h`, `7d`, `weekly`, …).
    public static func quotaWindow(for window: QuotaWindow) -> String? {
        if window.canonicalProviderKey == "minimax",
           let suffix = localMacSuffix(window.id),
           suffix.hasSuffix(":weekly") {
            return "weekly"
        }
        if let token = window.window?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return normalizeQuotaWindowToken(token)
        }
        if let suffix = localMacSuffix(window.id) {
            return inferredQuotaWindow(from: suffix, provider: window.canonicalProviderKey)
        }
        return nil
    }

    // MARK: - local-mac ids

    private static func localMacSuffix(_ id: String) -> String? {
        let prefix = "local-mac:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        return String(rest[rest.index(after: separator)...])
    }

    private static func localMacProviderSegment(_ id: String) -> String? {
        let prefix = "local-mac:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let separator = rest.firstIndex(of: ":") else { return nil }
        return String(rest[..<separator])
    }

    private static func localMacBucketId(_ window: QuotaWindow) -> String? {
        guard let suffix = localMacSuffix(window.id),
              let segment = localMacProviderSegment(window.id) else { return nil }
        switch segment {
        case "anthropic":
            return "anthropic:\(suffix)"
        case "openai":
            return "openai:\(suffix)"
        case "xai":
            if suffix == "subscription" { return "xai:subscription" }
            return "xai:\(suffix)"
        case "grok-bot":
            return suffix
        case "minimax":
            if suffix.hasSuffix(":weekly") {
                let model = String(suffix.dropLast(":weekly".count))
                return "minimax:\(model):weekly"
            }
            if suffix.hasSuffix(":interval") {
                let model = String(suffix.dropLast(":interval".count))
                return "minimax:\(model)"
            }
            return "minimax:\(suffix)"
        default:
            return "\(window.canonicalProviderKey):\(suffix)"
        }
    }

    private static func fallbackBucketId(_ window: QuotaWindow) -> String {
        let provider = window.canonicalProviderKey
        if provider == "anthropic" {
            if let key = anthropicRateLimitKey(from: window) {
                return "anthropic:\(key)"
            }
        }
        if provider == "openai", let slot = codexSlot(from: window) {
            return "openai:\(slot)"
        }
        if provider == "xai" || provider == "grok-bot" {
            let token = window.window ?? "gbu-weekly"
            return provider == "grok-bot" ? token : "xai:\(token)"
        }
        if provider == "minimax", let model = window.modelId {
            return "minimax:\(model)"
        }
        if let modelId = window.modelId, !modelId.isEmpty {
            let cadence = window.window ?? "window"
            return "\(modelId)-\(cadence)"
        }
        return window.window ?? window.label.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private static func anthropicRateLimitKey(from window: QuotaWindow) -> String? {
        if let suffix = localMacSuffix(window.id) { return suffix }
        let model = window.modelId?.lowercased()
        let cadence = normalizeQuotaWindowToken(window.window ?? "")
        if let model, !model.isEmpty {
            let prefix = cadence == "5h" ? "five_hour" : "seven_day"
            return "\(prefix)_\(model)"
        }
        switch cadence {
        case "5h": return "five_hour"
        case "7d", "168h", "weekly", "1w": return "seven_day"
        default: break
        }
        let label = window.label.lowercased()
        if label.contains("fable") { return (label.contains("5h") || label.contains("5-hour")) ? "five_hour_fable" : "seven_day_fable" }
        if label.contains("opus") { return "seven_day_opus" }
        if label.contains("sonnet") { return "seven_day_sonnet" }
        if label.contains("5h") || label.contains("5-hour") { return "five_hour" }
        if label.contains("7d") || label.contains("weekly") { return "seven_day" }
        return nil
    }

    private static func codexSlot(from window: QuotaWindow) -> String? {
        if let suffix = localMacSuffix(window.id) { return suffix }
        let label = window.label.lowercased()
        if label.contains("primary") { return "primary" }
        if label.contains("secondary") { return "secondary" }
        return window.window
    }

    private static func inferredQuotaWindow(from suffix: String, provider: String) -> String? {
        if provider == "minimax", suffix.hasSuffix(":weekly") { return "weekly" }
        if provider == "minimax", suffix.hasSuffix(":interval") { return "5h" }
        if suffix == "subscription" { return nil }
        return nil
    }

    private static func normalizeQuotaWindowToken(_ token: String) -> String {
        let lower = token.lowercased()
        switch lower {
        case "weekly", "1w", "168h": return "7d"
        case "five_hour", "5-hour", "5 hour": return "5h"
        case "seven_day", "7-day", "7 day": return "7d"
        default: return token
        }
    }
}
