import Foundation

/// Coordinates the unified subscription allowance pool shared across Cursor,
/// xAI, Grok, and Grok Bot.
///
/// Under the hood, Cursor's included weekly pool (Composer / Grok), xAI's
/// subscription allowance, Grok's subscription credits, and Grok Bot's weekly
/// meter (Cursor DashboardService or `gbu`) tap into the same underlying pool.
/// When any one of these sources provides a live reading, that reading is
/// shared across all participant providers so none of them report "stale
/// reading" or "unavailable" while another source has a fresh reading.
public enum UnifiedSubscriptionPool {
    /// The canonical provider keys that participate in this shared pool.
    public static let participantKeys: Set<String> = ["cursor", "xai", "grok", "grok-bot"]

    /// Whether a window belongs to this shared subscription pool.
    public static func isPoolWindow(_ window: QuotaWindow) -> Bool {
        let key = window.canonicalProviderKey
        guard participantKeys.contains(key) else { return false }
        if window.isSupplementaryVideoQuota { return false }
        let lowerId = window.id.lowercased()
        let lowerLabel = window.label.lowercased()
        // Exclude API spend balances (e.g. xai:api-monthly)
        if lowerId.contains("api") || lowerLabel.contains("api") { return false }
        // Exclude metadata-only windows that carry no readings
        if lowerId.contains("plan-metadata") || lowerLabel.contains("plan details") { return false }
        return true
    }

    /// Finds the freshest, most authoritative reading among candidate windows.
    public static func freshestReading(in windows: [QuotaWindow], now: Date = Date()) -> QuotaWindow? {
        let candidates = windows.filter { isPoolWindow($0) && $0.hasReading }
        return candidates.max { a, b in
            let dateA = a.occurredDate ?? .distantPast
            let dateB = b.occurredDate ?? .distantPast
            if dateA != dateB { return dateA < dateB }
            let snapA = QuotaWindowSnapshot(window: a, now: now)
            let snapB = QuotaWindowSnapshot(window: b, now: now)
            if snapA.isFresh != snapB.isFresh { return !snapA.isFresh && snapB.isFresh }
            let localA = a.sourceApp == "local-mac"
            let localB = b.sourceApp == "local-mac"
            if localA != localB { return !localA && localB }
            return false
        }
    }

    /// Canonical pool window ID for a given participant key.
    public static func canonicalWindowId(for providerKey: String) -> String {
        switch providerKey {
        case "cursor": return "local-mac:cursor:plan"
        case "xai": return "local-mac:xai:plan"
        case "grok": return "local-mac:grok:subscription"
        case "grok-bot": return "local-mac:grok-bot:weekly"
        default: return "local-mac:\(providerKey):plan"
        }
    }

    /// Canonical pool window label for a given participant key.
    public static func canonicalWindowLabel(for providerKey: String) -> String {
        switch providerKey {
        case "cursor": return "Included plan"
        case "xai": return "Subscription window"
        case "grok": return "Subscription window"
        case "grok-bot": return "Included weekly"
        default: return "Subscription window"
        }
    }

    /// Creates an adapted pool window for the given participant key from a source window.
    public static func adapt(_ source: QuotaWindow, for providerKey: String) -> QuotaWindow {
        var copy = source
        copy.provider = QuotaProviders.label(for: providerKey)
        copy.providerKey = providerKey
        copy.providerLabel = QuotaProviders.label(for: providerKey)
        copy.id = canonicalWindowId(for: providerKey)
        copy.label = canonicalWindowLabel(for: providerKey)
        copy.remainingUnknown = false
        copy.sourceApp = source.sourceApp ?? "local-mac"
        return copy.normalizedForExport()
    }

    /// Updates or injects the freshest reading across all participant providers present
    /// or expected in the window list.
    public static func share(windows: [QuotaWindow], now: Date = Date(), targetKeys: Set<String>? = nil) -> [QuotaWindow] {
        guard let best = freshestReading(in: windows, now: now) else {
            return windows
        }

        let bestDate = best.occurredDate ?? .distantPast
        let keysToUpdate = targetKeys ?? participantKeys

        var result: [QuotaWindow] = []
        var participantsHandled = Set<String>()

        for window in windows {
            let key = window.canonicalProviderKey
            if keysToUpdate.contains(key) && isPoolWindow(window) {
                participantsHandled.insert(key)
                let windowDate = window.occurredDate ?? .distantPast
                if window.hasReading && windowDate >= bestDate {
                    // Current window is already as fresh or fresher than best
                    result.append(window)
                } else {
                    // Update this window with the fresher reading from best
                    var updated = window
                    updated.remainingPercent = best.remainingPercent
                    updated.absoluteRemaining = best.absoluteRemaining
                    updated.absoluteLimit = best.absoluteLimit
                    updated.quotaUnit = best.quotaUnit
                    updated.status = best.status
                    updated.isExhausted = best.isExhausted
                    updated.resetAt = best.resetAt ?? window.resetAt
                    updated.periodStart = best.periodStart ?? window.periodStart
                    updated.occurredAt = best.occurredAt
                    updated.source = best.source
                    updated.sourceApp = best.sourceApp ?? window.sourceApp ?? "local-mac"
                    updated.planName = window.planName ?? best.planName
                    updated.window = best.window ?? window.window ?? "weekly"
                    updated.remainingUnknown = false
                    updated.skip = best.skip
                    updated.skipReason = best.skipReason
                    result.append(updated.normalizedForExport())
                }
            } else {
                result.append(window)
            }
        }

        let presentKeys = Set(windows.map(\.canonicalProviderKey))
        for key in keysToUpdate where !participantsHandled.contains(key) {
            if presentKeys.contains(key) || targetKeys != nil {
                result.append(adapt(best, for: key))
            }
        }

        return result
    }
}
