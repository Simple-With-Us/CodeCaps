import Foundation

/// How long one period of a quota window lasts, read from the cadence token or
/// label a provider reports, and the short tag the owner reads for it.
///
/// The Mac app derives the same thing from its richer window snapshots; this is
/// the token-and-label version the iOS companion uses, where all it has is the
/// wire window.  Plain Foundation, so the iOS targets compile this file directly.
///
/// The resolver here is the one every surface asks:  the Mac's caption, the
/// Mac's elapsed-time marker, the phone's marker and the widget's marker.  They
/// were four resolvers, and they read the same window differently, so a label
/// naming both a five hour window and a day took a "5h" caption beside a marker
/// drawn for a whole day, which puts the marker in the wrong place (owner,
/// Oct-22-2026).
public enum ResetAlarmCadence {
    /// A period, as a fixed span of seconds or as whole calendar months.
    ///
    /// A month is not a fixed number of seconds, so a monthly plan is counted
    /// on a calendar and never as "30 days" when the bar draws its marker.
    public enum Period: Equatable, Sendable {
        /// A fixed span of wall-clock time:  5h,  7d,  168h.
        case fixed(TimeInterval)
        /// Whole calendar months:  a monthly plan or a billing cycle.
        case calendarMonths(Int)
    }

    /// The calendar whole months are counted on:  Gregorian, fixed to UTC.
    ///
    /// Provider billing anchors are UTC instants, so "one month before the
    /// reset" has to be worked out in UTC.  On a local calendar the same reset
    /// lands on a different local date depending on where the Mac is, which
    /// skews the period length and puts the marker in the wrong place.  A fixed
    /// calendar also means two Macs in different time zones draw the same bar.
    public static let billingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// The one resolver for how long a window's period lasts.
    ///
    /// The rules, in the order they apply:
    ///
    /// - MiniMax has no four hour window:  its coding plan is five hours.
    /// - The token is the reader's own statement of the period, computed from
    ///   real timestamps, so it wins:  a "31d" token is thirty-one days.
    /// - A token that names a month is a calendar month.
    /// - A window that resets with a billing cycle is a calendar month, even
    ///   when it carries no cadence of its own.
    /// - The label is the fallback, and the hour forms come first:  a window
    ///   that names a five hour window beside a day is a five hour window.
    ///
    /// Returns nil when nothing names a period, for example a plan meter whose
    /// only token is "plan".
    public static func resolve(
        token: String?,
        label: String,
        providerKey: String? = nil,
        isSupplementaryVideoQuota: Bool = false,
        monthlyHint: Bool = false
    ) -> Period? {
        let token = (token ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let label = label.lowercased()
        let named = "\(token) \(label)"

        if providerKey == "minimax", !isSupplementaryVideoQuota, namesFourHours(named) {
            return .fixed(5 * 3_600)
        }
        if let strict = strictPeriod(token) { return strict }
        switch token {
        case "billing-cycle", "billing_cycle", "billing cycle", "billingcycle", "monthly", "month":
            return .calendarMonths(1)
        default:
            break
        }
        if monthlyHint { return .calendarMonths(1) }
        // Cursor's included plan resets with Cursor's monthly billing cycle and
        // carries no cadence of its own.
        if providerKey == "cursor", named.contains("plan") { return .calendarMonths(1) }
        return prosePeriod(token: token, label: label)
    }

    /// The period in seconds.  A calendar month reads as the thirty days the
    /// pacing text has always used for it.
    public static func seconds(for period: Period) -> TimeInterval {
        switch period {
        case .fixed(let seconds): return seconds
        case .calendarMonths(let months): return TimeInterval(months) * 30 * 86_400
        }
    }

    /// When a period that ends at `end` began.  A monthly period is one
    /// calendar month before the reset, so a reset on Mar 31 starts on Feb 28
    /// and a reset on Mar 1 starts on Feb 1.
    public static func start(of period: Period, endingAt end: Date) -> Date? {
        switch period {
        case .fixed(let seconds):
            guard seconds.isFinite, seconds > 0 else { return nil }
            return end.addingTimeInterval(-seconds)
        case .calendarMonths(let months):
            guard months > 0 else { return nil }
            return billingCalendar.date(byAdding: .month, value: -months, to: end)
        }
    }

    /// One period in seconds, or `nil` when neither the token nor the label says.
    /// `monthlyHint` marks a window that resets with a billing cycle but carries
    /// no cadence of its own (Cursor's included plan).
    public static func periodSeconds(token: String?, label: String, monthlyHint: Bool = false) -> TimeInterval? {
        let cleaned = (token ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = durationSeconds(cleaned) {
            return seconds
        }
        // A session is not a period:  the window carries no cadence of its own,
        // so it is counted as the five hour allowance it really is.
        if cleaned == "session" { return 5 * 3_600 }
        guard let period = resolve(token: token, label: label, monthlyHint: monthlyHint) else { return nil }
        return seconds(for: period)
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

    // MARK: - The resolver's own rules

    /// A number followed by a unit: "5h", "168h", "1w", "31d", "1mo".  Nil for
    /// anything else, so free text falls through to the label rules.
    private static func strictPeriod(_ token: String) -> Period? {
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let value = Double(digits), value.isFinite, value > 0 else { return nil }
        let unit = String(token.dropFirst(digits.count)).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "s", "sec", "secs", "second", "seconds": return .fixed(value)
        case "m", "min", "mins", "minute", "minutes": return .fixed(value * 60)
        case "h", "hr", "hrs", "hour", "hours": return .fixed(value * 3_600)
        case "d", "day", "days": return .fixed(value * 86_400)
        case "w", "wk", "wks", "week", "weeks": return .fixed(value * 604_800)
        case "mo", "mos", "month", "months":
            guard value == value.rounded(), value <= 24 else { return nil }
            return .calendarMonths(Int(value))
        default: return nil
        }
    }

    /// The period a window's own words name, when its token does not.
    ///
    /// The words are read whole, so "24h" is one word and never the "4h" inside
    /// it, and "12-hour" is twelve hours and never the "2-hour" inside it.
    private static func prosePeriod(token: String, label: String) -> Period? {
        let named = "\(token) \(label)".lowercased()
        let words = words(named)

        if let hours = hourCount(in: words) {
            return .fixed(TimeInterval(hours) * 3_600)
        }
        if named.contains("coding plan") || named.contains("coding_plan") || named.contains("interval") {
            return .fixed(5 * 3_600)
        }
        if let days = dayCount(in: words) {
            if (28...31).contains(days) { return .calendarMonths(1) }
            return .fixed(TimeInterval(days) * 86_400)
        }
        if words.contains(where: { weeklyWords.contains($0) }) { return .fixed(7 * 86_400) }
        if words.contains(where: { monthlyWords.contains($0) }) { return .calendarMonths(1) }
        if words.contains(where: { dailyWords.contains($0) }) { return .fixed(86_400) }
        return nil
    }

    /// Whether the window names a four hour period, which only MiniMax does
    /// and never means.
    private static func namesFourHours(_ named: String) -> Bool {
        named.contains("4h") || named.contains("4-hour") || named.contains("4 hour")
    }

    /// The words of a label or a token, split on everything that is neither a
    /// letter nor a digit, so "5-hour" reads as "5" and "hour" and "24h" reads
    /// as one word.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The number of hours a window names, when it names one.
    ///
    /// The words are read whole, so "24h" is one word and never the "4h" inside
    /// it, and "12-hour" is twelve hours and never the "2-hour" inside it.
    /// A count of a day or more is still a count of hours, so "24h" is a day.
    private static func hourCount(in words: [String]) -> Int? {
        for (index, word) in words.enumerated() {
            if word.hasSuffix("h"), let value = Int(word.dropLast()), value > 0 {
                return value
            }
            guard index + 1 < words.count, isHourWord(words[index + 1]) else { continue }
            if let value = Int(word), value > 0 { return value }
            if let value = spelledNumbers[word], value > 0 { return value }
        }
        return nil
    }

    /// The number of days a window names, when it names one.
    ///
    /// A week reads as seven days, so "1w" and "7 day" both read as a week.
    private static func dayCount(in words: [String]) -> Int? {
        for (index, word) in words.enumerated() {
            if word.hasSuffix("d"), let value = Int(word.dropLast()), value > 0 {
                return value
            }
            if word.hasSuffix("w"), let value = Int(word.dropLast()), value > 0 {
                return value * 7
            }
            guard index + 1 < words.count else { continue }
            if words[index + 1] == "day" || words[index + 1] == "days" {
                if let value = Int(word), value > 0 { return value }
            }
        }
        return nil
    }

    private static func isHourWord(_ word: String) -> Bool {
        word == "hour" || word == "hours" || word == "hr" || word == "hrs"
    }

    private static let spelledNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12
    ]

    private static let weeklyWords: Set<String> = ["weekly", "week", "weeks"]
    private static let monthlyWords: Set<String> = ["monthly", "month", "months", "billing", "cycle"]
    private static let dailyWords: Set<String> = ["daily", "day", "days"]
}
