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

    /// The calendar whole months are counted on: Gregorian, fixed to UTC.
    ///
    /// Provider billing anchors are UTC instants, so "one month before the
    /// reset" has to be worked out in UTC.  On the Mac's local calendar the same
    /// reset lands on a different local date depending on where the Mac is, which
    /// skews the period length (a Mar 1 03:00Z reset would start on Jan 29 in
    /// Chicago) and puts the marker in the wrong place.  A fixed calendar also
    /// means two Macs in different time zones draw the same bar.
    public static let billingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// When a window of this length that ends at `end` began.  Months are counted
    /// on `billingCalendar` unless a caller passes another.
    public func start(endingAt end: Date, calendar: Calendar = QuotaPeriod.billingCalendar) -> Date? {
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
        calendar: Calendar = QuotaPeriod.billingCalendar
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
    func periodSpan(calendar: Calendar = QuotaPeriod.billingCalendar) -> QuotaPeriodSpan? {
        QuotaPeriodSpan.resolve(
            token: window.window,
            label: window.label,
            resetAt: resetAt,
            explicitStart: window.periodStartDate,
            calendar: calendar
        )
    }

    /// How far through its period the window is, 0...1, or nil when unknown.
    func elapsedFraction(now: Date, calendar: Calendar = QuotaPeriod.billingCalendar) -> Double? {
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

    public init(snapshot: QuotaWindowSnapshot, now: Date, calendar: Calendar = QuotaPeriod.billingCalendar) {
        self.init(remainingPercent: snapshot.remainingPercent,
                  elapsedFraction: snapshot.elapsedFraction(now: now, calendar: calendar))
    }

    public var hasReading: Bool { remainingPercent != nil }

    /// Share used, 0...1: `100 - remaining`.
    public var usedFraction: Double? { remainingPercent.map { (100 - $0) / 100 } }

    /// The remaining percentage exactly as the row prints it.
    public var remainingPercentRounded: Int? { remainingPercent.map { Int($0.rounded()) } }

    /// The used percentage, from the rounded remaining figure so the two spoken
    /// numbers always add to 100.
    public var usedPercentRounded: Int? { remainingPercentRounded.map { 100 - $0 } }

    public var elapsedPercentRounded: Int? { elapsedFraction.map { Int(($0 * 100).rounded()) } }

    /// A segment narrower than this is not drawn: at half a point it is an
    /// anti-aliased smudge, not a colour.
    public static let minimumSegmentWidth: Double = 0.5

    /// The widths of the red and green segments across `totalWidth`.  The green
    /// segment takes whatever the red one leaves, so the two always fill the bar
    /// with no seam.  Nil when the reading is unknown.
    ///
    /// A bar that reads 100% draws no red at all, and one that reads 0% draws
    /// no green.  "Reads" means the printed, rounded figure, so a window at
    /// 99.6% never shows a red sliver under a "100%" label; and any segment
    /// narrower than `minimumSegmentWidth` is dropped for the same reason.
    public func segmentWidths(in totalWidth: Double) -> (used: Double, remaining: Double)? {
        guard let usedFraction else { return nil }
        let width = totalWidth.isFinite ? max(0, totalWidth) : 0
        var used = width * usedFraction
        if remainingPercentRounded == 100 || used < Self.minimumSegmentWidth { used = 0 }
        if remainingPercentRounded == 0 || width - used < Self.minimumSegmentWidth { used = width }
        return (used, width - used)
    }

    /// Where the marker and the pale halo behind it are drawn on a bar
    /// `totalWidth` wide and `barHeight` thick, or nil when there is no marker.
    ///
    /// The marker is kept wholly inside the bar's ends, and the halo, which
    /// stands `haloPadding` proud of it on each side, is cut off at them.
    ///
    /// And the marker never leaves a sliver of bar hanging off it.  Next to an
    /// end, the bar left over between the marker and that end is a rounded cap
    /// and nothing more (at 100% remaining with the period just begun, it was a
    /// small "c" left of the marker).  When that stub would be narrower than
    /// the bar's own cap, the marker moves the few points to the end instead,
    /// flush with it, where it stands over the cap as it does at 0% elapsed.
    /// The bar itself is never trimmed or masked, so the red and green it draws
    /// are always the share the reading says, and its end stays in line with
    /// every other bar in its column.
    public func markerLayout(in totalWidth: Double, barHeight: Double,
                             markerWidth: Double, haloPadding: Double) -> QuotaMarkerLayout? {
        guard let elapsedFraction else { return nil }
        let width = totalWidth.isFinite ? max(0, totalWidth) : 0
        guard width > markerWidth else {
            return QuotaMarkerLayout(center: width / 2, haloStart: 0, haloEnd: width)
        }
        let half = markerWidth / 2
        var center = min(max(width * elapsedFraction, half), width - half)
        // A bar too short to hold the marker and a whole cap either side keeps
        // the marker where the time is.
        let cap = max(0, barHeight) / 2
        if width >= (half + cap) * 2 {
            if center - half < cap { center = half }
            else if width - (center + half) < cap { center = width - half }
        }
        let reach = half + max(0, haloPadding)
        return QuotaMarkerLayout(center: center,
                                 haloStart: max(0, center - reach), haloEnd: min(width, center + reach))
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

/// The horizontal extent of an elapsed-time marker and its halo, in points from
/// the bar's left end.  See `QuotaBarMetrics.markerLayout`.
public struct QuotaMarkerLayout: Equatable, Sendable {
    /// The marker's centre.
    public let center: Double
    /// The halo's left and right edges.
    public let haloStart: Double
    public let haloEnd: Double

    public var haloWidth: Double { haloEnd - haloStart }
    public var haloCenter: Double { (haloStart + haloEnd) / 2 }
}
