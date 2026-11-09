import Foundation

/// The one rule that decides whether a quota window is the short or long meter
/// in a two-bar row.
///
/// The Mac's Glance panel, the phone companion, and the widgets all ask this
/// question when they call `QuotaWindowPairing.meterPair`.  They used to answer
/// it three different ways;  a widget that measured period length with
/// `period < 86_400` treated MiniMax's daily interval as long while the Mac
/// treated a coding-plan interval as short, so the pair disagreed about which
/// two meters to draw (CC-223).
public enum QuotaMeterCadence {
    /// Whether the window belongs in the short meter slot of a two-bar row.
    public static func isShort(
        windowToken: String?,
        label: String,
        cadence: String = "",
        resetAt: Date? = nil,
        now: Date = Date(),
        isSupplementaryVideoQuota: Bool = false
    ) -> Bool {
        if isSupplementaryVideoQuota { return true }

        let token = (windowToken ?? "")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = durationSeconds(token) {
            return seconds < 86_400
        }
        switch token {
        case "session", "fast":
            return true
        case "weekly", "week", "monthly", "month", "plan", "included plan":
            return false
        default:
            break
        }

        let haystack = ((cadence.isEmpty ? label : cadence) + " " + label + " " + token)
            .lowercased()
        if haystack.contains("7d") || haystack.contains("1w") || haystack.contains("weekly")
            || haystack.contains("month") || haystack.contains("billing")
            || haystack.contains("cycle") || haystack.contains("30d")
            || haystack.contains("1m") || haystack.contains("org") || haystack.contains("quota")
        {
            return false
        }
        if haystack.contains("5h") || haystack.contains("5-hour") || haystack.contains("5 hour")
            || haystack.contains("five_hour") || haystack.contains("4h")
            || haystack.contains("4-hour") || haystack.contains("4 hour")
            || haystack.contains("four_hour") || haystack.contains("session")
            || haystack.contains("fast") || haystack.contains("coding plan")
            || haystack.contains("coding_plan") || haystack.contains("interval")
        {
            return true
        }
        if haystack.contains("plan") { return false }

        if let sec = ResetAlarmCadence.periodSeconds(token: cadence.isEmpty ? token : cadence, label: label) {
            return sec < 86_400
        }
        if let resetAt, resetAt > now {
            return resetAt.timeIntervalSince(now) < 86_400
        }
        return false
    }

    /// Reads a duration token such as `5h`, `300m`, `168h`, or `1w` into seconds.
    public static func durationSeconds(_ token: String) -> TimeInterval? {
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(digits), value > 0 else { return nil }
        let unit = String(token.dropFirst(digits.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch unit {
        case "s", "sec", "secs", "second", "seconds": return value
        case "m", "min", "mins", "minute", "minutes": return value * 60
        case "h", "hr", "hrs", "hour", "hours": return value * 3_600
        case "d", "day", "days": return value * 86_400
        case "w", "week", "weeks": return value * 604_800
        default: return nil
        }
    }
}
