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
        switch token {
        case "session", "fast":
            return true
        case "weekly", "week", "monthly", "month", "plan", "included plan":
            return false
        default:
            break
        }

        // The wording signal is read the way the companion always read it:
        // first the cadence (or, bare, the label), then the label itself, so
        // a formatted cadence that lost the interval wording ("1-day" for
        // "general (interval window)") still finds it (CC-223).  A generic
        // display label such as "Quota" never classifies on its own when the
        // cadence already spoke.
        let primary = (cadence.isEmpty ? label : cadence).lowercased()
        let secondary = label.lowercased()
        for text in [primary, secondary] {
            if text.contains("7d") || text.contains("1w") || text.contains("weekly")
                || text.contains("month") || text.contains("billing")
                || text.contains("cycle") || text.contains("30d")
                || text.contains("1m") || text.contains("org") || text.contains("quota")
            {
                return false
            }
            if text.contains("5h") || text.contains("5-hour") || text.contains("5 hour")
                || text.contains("five_hour") || text.contains("4h")
                || text.contains("4-hour") || text.contains("4 hour")
                || text.contains("four_hour") || text.contains("session")
                || text.contains("fast") || text.contains("coding plan")
                || text.contains("coding_plan") || text.contains("interval")
            {
                return true
            }
        }
        if primary.contains("plan") || secondary.contains("plan") { return false }

        // A bare duration token decides only after the interval and plan
        // wordings above:  MiniMax's daily interval reads as a short meter on
        // every surface (CC-223), so the "1d" token alone must not overrule it.
        if let seconds = durationSeconds(token) {
            return seconds < 86_400
        }
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
