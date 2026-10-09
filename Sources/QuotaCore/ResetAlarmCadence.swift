import Foundation

/// How long one period of a quota window lasts, read from the cadence token or
/// label a provider reports, and the short tag the owner reads for it.
///
/// The Mac app derives the same thing from its richer window snapshots; this is
/// the token-and-label version the iOS companion uses, where all it has is the
/// wire window.  Plain Foundation, so the iOS targets compile this file directly.
public enum ResetAlarmCadence {
    /// One period in seconds, or `nil` when neither the token nor the label says.
    /// `monthlyHint` marks a window that resets with a billing cycle but carries
    /// no cadence of its own (Cursor's included plan).
    public static func periodSeconds(token: String?, label: String, monthlyHint: Bool = false) -> TimeInterval? {
        let cleaned = (token ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = durationSeconds(cleaned) {
            return seconds
        }
        let named = cleaned + " " + label.lowercased()
        if monthlyHint || named.contains("month") || named.contains("billing") || named.contains("cycle") {
            return 30 * 86_400
        }
        if named.contains("weekly") || named.contains("7-day") || named.contains("seven_day")
            || named.contains("7d") || named.contains("1w") {
            return 7 * 86_400
        }
        if named.contains("5-hour") || named.contains("5 hour") || named.contains("five_hour") || named.contains("5h") {
            return 5 * 3_600
        }
        if named.contains("daily") || named.contains("1d") { return 86_400 }
        switch cleaned {
        case "session": return 5 * 3_600
        case "day": return 86_400
        default: return nil
        }
    }

    /// A duration token such as "5h", "300m", "168h" or "1w" in seconds; `nil`
    /// for anything that is not a number followed by a time unit.
    public static func durationSeconds(_ token: String) -> TimeInterval? {
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(digits), value > 0 else { return nil }
        var unit = String(token.dropFirst(digits.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if unit.hasPrefix("-") || unit.hasPrefix("_") {
            unit = String(unit.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch unit {
        case "s", "sec", "secs", "second", "seconds": return value
        case "m", "min", "mins", "minute", "minutes": return value * 60
        case "h", "hr", "hrs", "hour", "hours": return value * 3_600
        case "d", "day", "days": return value * 86_400
        case "w", "week", "weeks": return value * 604_800
        default: return nil
        }
    }

    /// The tag beside a window: "5h", "7d", "1m".  Days first, so a weekly window
    /// reads "7d" rather than "1w", and any 28 to 31 day window reads "1m".
    public static func caption(forPeriod seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        if whole % 86_400 == 0 {
            let days = whole / 86_400
            return (28...31).contains(days) ? "1m" : "\(days)d"
        }
        if whole % 3_600 == 0 { return "\(whole / 3_600)h" }
        if whole % 60 == 0 { return "\(whole / 60)m" }
        return "\(whole)s"
    }
}
