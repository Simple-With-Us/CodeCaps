import Foundation

// The math behind the two-segment quota bar and its elapsed-time marker.
//
// Everything a bar has to decide lives here, as pure functions of a snapshot and
// a clock, so it can be unit tested without rendering a view: how long a window
// lasts, where it started, how far through it we are, and how wide the red and
// green segments are.  The SwiftUI layer only draws what these types return.

// MARK: - Period

/// How long a quota window lasts, as its provider defines it.
public enum QuotaPeriod: Equatable, Sendable {
    /// A fixed span of wall-clock time: 5h, 7d, 168h.
    case fixed(TimeInterval)
    /// Whole calendar months: a monthly plan or billing cycle.  A month is not a
    /// fixed number of seconds, so its span is measured on a calendar, never as
    /// "30 days".
    case calendarMonths(Int)

    /// When a window of this length that ends at `end` began.
    public func start(endingAt end: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .fixed(let seconds):
            guard seconds.isFinite, seconds > 0 else { return nil }
            return end.addingTimeInterval(-seconds)
        case .calendarMonths(let months):
            guard months > 0 else { return nil }
            return calendar.date(byAdding: .month, value: -months, to: end)
        }
    }

    /// Reads a window's period from its own duration token first and its label
    /// second.
    ///
    /// The token comes from the reader, computed from real timestamps, so it
    /// wins over label prose: a "31d" token is thirty-one days.  The looser
    /// substring rules in `WindowPacing.parseDurationSeconds` would read "31d"
    /// as one day ("1d") and "15h" as five hours ("5h"), so they are only a
    /// fallback for tokens that are not a number and a unit.
    ///
    /// Returns nil when nothing names a period, for example a plan meter whose
    /// only token is "plan".
    public static func resolve(token: String?, label: String) -> QuotaPeriod? {
        let token = (token ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let strict = strictPeriod(token) { return strict }

        switch token {
        case "billing-cycle", "billing_cycle", "billing cycle", "billingcycle", "monthly", "month":
            return .calendarMonths(1)
        default:
            break
        }

        let words = "\(token) \(label.lowercased())"
        if let seconds = WindowPacing.parseDurationSeconds(token: token, label: label) {
            // The loose parser calls any "month" a fixed 30 days.
            if seconds == 30 * 86_400, words.contains("month") { return .calendarMonths(1) }
            return .fixed(seconds)
        }
        if words.contains("billing cycle") || words.contains("billing-cycle") || words.contains("monthly") {
            return .calendarMonths(1)
        }
        return nil
    }

    /// A number followed by a unit: "5h", "168h", "1w", "31d", "1mo".  Nil for
    /// anything else, so free text falls through to the keyword rules.
    private static func strictPeriod(_ token: String) -> QuotaPeriod? {
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
}

/// The interval a quota window covers, ending at its reset.
public struct QuotaPeriodSpan: Equatable, Sendable {
    public let start: Date
    public let end: Date

    /// No quota window lasts longer than this, so a span that does is a bad
    /// timestamp and is not drawn.
    public static let maximumDuration: TimeInterval = 400 * 86_400

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// How far through the span `now` is: 0 at the start, 1 at or after the
    /// reset.
    public func elapsedFraction(at now: Date) -> Double {
        let total = duration
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Resolves the span a window covers.
    ///
    /// An explicit period start from the provider wins.  Otherwise the start is
    /// derived from the reset and the window's period, and a monthly period is
    /// one calendar month before the reset date, so a reset on Mar 31 starts on
    /// Feb 28 and a reset on Mar 1 starts on Feb 1.  Returns nil when the reset
    /// is unknown or no period can be read.
    public static func resolve(
        token: String?,
        label: String,
        resetAt: Date?,
        explicitStart: Date? = nil,
        calendar: Calendar = .current
    ) -> QuotaPeriodSpan? {
        guard let resetAt else { return nil }
        if let explicitStart, isPlausible(start: explicitStart, end: resetAt) {
            return QuotaPeriodSpan(start: explicitStart, end: resetAt)
        }
        guard let start = QuotaPeriod.resolve(token: token, label: label)?
            .start(endingAt: resetAt, calendar: calendar),
            isPlausible(start: start, end: resetAt) else { return nil }
        return QuotaPeriodSpan(start: start, end: resetAt)
    }

    private static func isPlausible(start: Date, end: Date) -> Bool {
        let span = end.timeIntervalSince(start)
        return span.isFinite && span > 0 && span <= maximumDuration
    }
}

public extension QuotaWindowSnapshot {
    /// The interval this window covers, or nil when its reset or its period is
    /// unknown.  Such a window draws no elapsed-time marker.
    func periodSpan(calendar: Calendar = .current) -> QuotaPeriodSpan? {
        QuotaPeriodSpan.resolve(
            token: window.window,
            label: window.label,
            resetAt: resetAt,
            explicitStart: window.periodStartDate,
            calendar: calendar
        )
    }

    /// How far through its period the window is, 0...1, or nil when unknown.
    func elapsedFraction(now: Date, calendar: Calendar = .current) -> Double? {
        periodSpan(calendar: calendar)?.elapsedFraction(at: now)
    }
}

// MARK: - Bar geometry

/// What one quota bar shows: a red segment for the share used and a green
/// segment for the share left, from the left edge to the right, and a marker at
/// the fraction of the period that has elapsed.
///
/// Red running past the marker means the window is being burned faster than time
/// passes, which is the point of drawing them on the same axis.
public struct QuotaBarMetrics: Equatable, Sendable {
    /// Share left, 0...100.  Nil when the reading is unknown, in which case the
    /// bar draws its neutral empty track instead of two segments.
    public let remainingPercent: Double?
    /// How far through the period we are, 0...1.  Nil draws no marker.
    public let elapsedFraction: Double?

    public init(remainingPercent: Double?, elapsedFraction: Double?) {
        if let remainingPercent, remainingPercent.isFinite {
            self.remainingPercent = min(100, max(0, remainingPercent))
        } else {
            self.remainingPercent = nil
        }
        if let elapsedFraction, elapsedFraction.isFinite {
            self.elapsedFraction = min(1, max(0, elapsedFraction))
        } else {
            self.elapsedFraction = nil
        }
    }

    public init(snapshot: QuotaWindowSnapshot, now: Date, calendar: Calendar = .current) {
        self.init(remainingPercent: snapshot.remainingPercent,
                  elapsedFraction: snapshot.elapsedFraction(now: now, calendar: calendar))
    }

    public var hasReading: Bool { remainingPercent != nil }

    /// Share used, 0...1: `100 - remaining`.
    public var usedFraction: Double? { remainingPercent.map { (100 - $0) / 100 } }

    /// Share left, 0...1.
    public var remainingFraction: Double? { remainingPercent.map { $0 / 100 } }

    /// The remaining percentage exactly as the row prints it.
    public var remainingPercentRounded: Int? { remainingPercent.map { Int($0.rounded()) } }

    /// The used percentage, from the rounded remaining figure so the two spoken
    /// numbers always add to 100.
    public var usedPercentRounded: Int? { remainingPercentRounded.map { 100 - $0 } }

    public var elapsedPercentRounded: Int? { elapsedFraction.map { Int(($0 * 100).rounded()) } }

    /// The widths of the red and green segments across `totalWidth`.  The green
    /// segment takes whatever the red one leaves, so the two always fill the bar
    /// with no seam.  Nil when the reading is unknown.
    public func segmentWidths(in totalWidth: Double) -> (used: Double, remaining: Double)? {
        guard let usedFraction else { return nil }
        let width = totalWidth.isFinite ? max(0, totalWidth) : 0
        let used = width * usedFraction
        return (used, width - used)
    }

    /// Where the marker's centre sits across `totalWidth`, kept `inset` points
    /// inside both ends so it stays visible at 0% and 100% elapsed.
    public func markerOffset(in totalWidth: Double, inset: Double = 1) -> Double? {
        guard let elapsedFraction else { return nil }
        let width = totalWidth.isFinite ? max(0, totalWidth) : 0
        guard width > inset * 2 else { return width / 2 }
        return min(max(width * elapsedFraction, inset), width - inset)
    }

    /// What VoiceOver says: both shares and how far through the period we are,
    /// for example "85 percent remaining, 15 percent used, 40 percent of period
    /// elapsed".
    public var spokenSummary: String {
        var parts: [String] = []
        if let remaining = remainingPercentRounded, let used = usedPercentRounded {
            parts.append("\(remaining) percent remaining")
            parts.append("\(used) percent used")
        } else {
            parts.append("no reading")
        }
        if let elapsed = elapsedPercentRounded {
            parts.append("\(elapsed) percent of period elapsed")
        }
        return parts.joined(separator: ", ")
    }
}
