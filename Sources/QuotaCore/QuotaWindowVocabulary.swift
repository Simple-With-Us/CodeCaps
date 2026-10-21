import Foundation

/// Canonical quota-window names shared across Mac, iOS, widgets, and readers.
///
/// Standard labels use hyphenated cadence copy ("5-hour", "7-day", "1-month",
/// "Other limit").  The menu-bar popover keeps the owner-approved compact
/// captions ("5h", "7d", "1m") via `popoverCaption`.
public enum QuotaWindowVocabulary {
    public static let fiveHour = "5-hour"
    public static let oneDay = "1-day"
    public static let sevenDay = "7-day"
    public static let oneMonth = "1-month"
    public static let otherLimit = "Other limit"

    /// Short distinguishing nouns for the widget caption row.
    ///
    /// These sit *next to* the cadence token (`5h`, `7d`, `1m`) and must not
    /// repeat its cadence form; "7-day" beside a `7d` token is the duplication
    /// owner 2026-10-21 caught on the Antigravity weekly row.  A noun that
    /// names the window kind ("weekly", "monthly", "additional") is what the
    /// caption needs when two bars share one cadence.
    public static let barQualifierWeekly = "weekly"
    public static let barQualifierMonthly = "monthly"
    /// Not "daily": the caption already shows the `1d` token, so the
    /// qualifier must not restate the same cadence.  "daily allowance" names
    /// the kind of allowance instead.
    public static let barQualifierDaily = "daily allowance"
    public static let barQualifierHourly = "hourly"
    public static let barQualifierAdditional = "additional"

    /// The cadence forms a bar qualifier must never repeat: the hyphenated
    /// labels and the compact tokens the caption row already carries beside
    /// the qualifier.
    public static let barQualifierForbiddenCadenceForms = [
        fiveHour, oneDay, sevenDay, oneMonth, otherLimit,
        "5h", "1d", "7d", "1m", "+"
    ]

    /// The caption facts of one quota bar: the cadence it shows and the label
    /// it carries.  A row of bars is resolved together, because whether a bar
    /// needs a qualifier depends on the bars beside it.
    public struct BarCaption: Equatable, Sendable {
        public let cadence: String
        public let label: String

        public init(cadence: String, label: String) {
            self.cadence = cadence
            self.label = label
        }
    }

    /// The lowercased lexical tokens of a label, split on everything that is
    /// not a letter or a number.
    ///
    /// Canonical qualifiers are matched against these tokens and never as
    /// substrings, so a label such as "nothourly" is not an hourly window.
    public static func lexicalTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    /// The short distinguishing noun for a bar caption row, or "" when the
    /// label names none.
    ///
    /// "Free weekly limit" reads "weekly", "Additional tokens" reads
    /// "additional", and a label with no such word reads nothing.
    public static func barQualifier(forLabel label: String) -> String {
        if isExtraAllowanceLabel(label) { return barQualifierAdditional }
        let tokens = lexicalTokens(label)
        if tokens.contains("weekly") { return barQualifierWeekly }
        if tokens.contains("monthly") || tokens.contains("billing") { return barQualifierMonthly }
        if tokens.contains("daily") { return barQualifierDaily }
        if tokens.contains("hourly") { return barQualifierHourly }
        return ""
    }

    /// The qualifier for a bar caption row, or "" when the row needs none.
    ///
    /// A cadence word is only worth printing when a sibling bar shares the
    /// cadence, because on a lone bar "7d weekly" says the same thing twice.
    public static func barQualifier(forLabel label: String, sharesCadence: Bool) -> String {
        guard sharesCadence else { return "" }
        return barQualifier(forLabel: label)
    }

    /// The canonical cadence a window belongs to, used to group the bars that
    /// share one period.
    public static func barCadenceGroup(cadence: String, label: String) -> String {
        let tokens = lexicalTokens(label)
        if tokens.contains("weekly") { return sevenDay }
        if tokens.contains("monthly") || tokens.contains("billing") { return oneMonth }
        if tokens.contains("daily") { return oneDay }
        if tokens.contains("hourly") { return fiveHour }
        if isExtraAllowanceLabel(label) {
            // An extra allowance is extra capacity of the period it doubles,
            // so it groups with that window rather than standing alone.
            return standardCadence(windowToken: cadence, label: "")
        }
        return standardCadence(windowToken: cadence, label: label)
    }

    /// The qualifier of every bar in a caption row, in the same order.
    ///
    /// Each bar is resolved against its siblings, so a bar that shares its
    /// cadence with another bar gets the word that tells the two apart and a
    /// lone bar gets none.
    public static func barQualifiers(forBars bars: [BarCaption]) -> [String] {
        let groups = bars.map { barCadenceGroup(cadence: $0.cadence, label: $0.label) }
        return bars.indices.map { index in
            let siblings = groups.indices.filter { $0 != index }.map { groups[$0] }
            return barQualifier(
                forLabel: bars[index].label,
                sharesCadence: siblings.contains(groups[index])
            )
        }
    }

    /// Full cadence label for a window, suitable for main-window copy and wire export.
    public static func standardCadence(
        windowToken: String?,
        label: String,
        resetAt: Date? = nil,
        periodStart: Date? = nil,
        monthlyHint: Bool = false
    ) -> String {
        let prose = stripTrailingWindowSuffix(label)
        if isExtraAllowanceLabel(prose) { return otherLimit }
        if let token = windowToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            if let fromToken = cadenceFromToken(token, label: label, resetAt: resetAt, periodStart: periodStart, monthlyHint: monthlyHint) {
                return fromToken
            }
        }
        if let fromLabel = cadenceFromProse(prose, resetAt: resetAt, periodStart: periodStart, monthlyHint: monthlyHint) {
            return fromLabel
        }
        if isOpaqueProviderKey(prose) { return classifyOpaqueKey(resetAt: resetAt, periodStart: periodStart) }
        return otherLimit
    }

    private static func stripTrailingWindowSuffix(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasSuffix(" window") {
            text = String(text.dropLast(" window".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Label stored on `QuotaWindow.label` (cadence plus optional " window" suffix stripped by callers).
    public static func windowLabel(
        windowToken: String?,
        existingLabel: String,
        resetAt: Date? = nil,
        periodStart: Date? = nil,
        monthlyHint: Bool = false
    ) -> String {
        let stripped = stripModelSuffix(from: existingLabel)
        if let separator = stripped.range(of: " · ") {
            let head = String(stripped[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(stripped[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let cadence = standardCadence(
                windowToken: windowToken,
                label: tail,
                resetAt: resetAt,
                periodStart: periodStart,
                monthlyHint: monthlyHint
            )
            return "\(head) · \(cadence)"
        }
        let cadence = standardCadence(
            windowToken: windowToken,
            label: stripped,
            resetAt: resetAt,
            periodStart: periodStart,
            monthlyHint: monthlyHint
        )
        return "\(cadence) window"
    }

    /// Rewrites labels that still carry model names, weekly shorthand, or opaque server keys.
    public static func sanitizeLabelIfNeeded(
        _ label: String,
        windowToken: String?,
        resetAt: Date?,
        periodStart: Date?,
        monthlyHint: Bool
    ) -> String? {
        let lower = label.lowercased()
        let needsRewrite = isOpaqueProviderKey(label)
            || isExtraAllowanceLabel(label)
            || lower.contains("(opus)")
            || lower.contains("(sonnet)")
            || lower.contains("(haiku)")
            || lower.contains("(model")
            || lower.contains("weekly")
            || lower.contains("additional-")
            || lower.contains("additional additional")
            || lower.contains("+ extra")
        guard needsRewrite else { return nil }
        return windowLabel(
            windowToken: windowToken,
            existingLabel: label,
            resetAt: resetAt,
            periodStart: periodStart,
            monthlyHint: monthlyHint
        )
    }

    /// Compact unit tag for the menu-bar popover meters (owner-approved layout).
    public static func popoverCaption(
        windowToken: String?,
        label: String,
        resetAt: Date? = nil,
        periodStart: Date? = nil,
        monthlyHint: Bool = false,
        isExtraAllowance: Bool = false
    ) -> String {
        if isExtraAllowance || isExtraAllowanceLabel(label) { return "+" }
        let cadence = standardCadence(
            windowToken: windowToken,
            label: label,
            resetAt: resetAt,
            periodStart: periodStart,
            monthlyHint: monthlyHint
        )
        switch cadence {
        case fiveHour: return "5h"
        case oneDay: return "1d"
        case sevenDay: return "7d"
        case oneMonth: return "1m"
        case otherLimit: return "+"
        default: return "Quota"
        }
    }

    public static func isExtraAllowanceLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        return lower.contains("additional additional")
            || lower.contains("additional allowance")
            || lower.contains("+ extra")
            || (lower.contains("additional") && lower.contains("extra"))
            || lower.hasSuffix(" extra")
    }

    public static func isOpaqueProviderKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(" ") || trimmed.contains("·") { return false }
        if looksLikeCadenceOnly(trimmed) { return false }
        // Rate-limit slot names (e.g. companion/server keys) use underscores.
        return trimmed.contains("_") || trimmed.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
            && !trimmed.contains("hour") && !trimmed.contains("day") && !trimmed.contains("week")
    }

    private static func classifyOpaqueKey(resetAt: Date?, periodStart: Date?) -> String {
        if let start = periodStart, let end = resetAt {
            let seconds = end.timeIntervalSince(start)
            if (27 * 86_400...31 * 86_400).contains(seconds) { return oneMonth }
        }
        if let end = resetAt, let start = periodStart {
            let seconds = end.timeIntervalSince(start)
            if seconds >= 6 * 86_400 { return sevenDay }
            if seconds >= 4 * 3_600 { return fiveHour }
        }
        return otherLimit
    }

    private static func cadenceFromToken(
        _ token: String,
        label: String,
        resetAt: Date?,
        periodStart: Date?,
        monthlyHint: Bool
    ) -> String? {
        let lower = token.lowercased()
        if ["5h", "5hr", "5-hour", "5hours", "300m"].contains(lower) { return fiveHour }
        if ["1d", "24h", "daily", "day"].contains(lower) { return oneDay }
        if ["7d", "168h", "1w", "weekly", "week"].contains(lower) { return sevenDay }
        if ["1m", "30d", "mo", "month", "monthly"].contains(lower) { return oneMonth }
        if let seconds = ResetAlarmCadence.durationSeconds(lower) {
            return cadenceFromDuration(seconds, label: label, monthlyHint: monthlyHint)
        }
        return cadenceFromProse(label, resetAt: resetAt, periodStart: periodStart, monthlyHint: monthlyHint)
    }

    private static func cadenceFromProse(
        _ label: String,
        resetAt: Date?,
        periodStart: Date?,
        monthlyHint: Bool
    ) -> String? {
        let lower = label.lowercased()
        if monthlyHint || lower.contains("billing") || lower.contains("cycle") || lower.contains("included plan") {
            return oneMonth
        }
        if lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("5h") || lower.contains("five_hour")
            || lower.contains("coding plan") || lower.contains("coding_plan") || lower.contains("interval") {
            return fiveHour
        }
        if lower.contains("1-day") || lower.contains("1 day") || lower.contains("daily") || lower.contains("24h") || (lower.contains("1d") && !lower.contains("1d-")) {
            return oneDay
        }
        if lower.contains("7-day") || lower.contains("7 day") || lower.contains("weekly") || lower.contains("7d") || lower.contains("1w") {
            return sevenDay
        }
        if lower.contains("month") || lower.contains("1-month") || lower.contains("30-day") || lower.contains("30d") {
            return oneMonth
        }
        if let start = periodStart, let end = resetAt {
            return cadenceFromDuration(end.timeIntervalSince(start), label: label, monthlyHint: monthlyHint)
        }
        return nil
    }

    private static func cadenceFromDuration(_ seconds: TimeInterval, label: String, monthlyHint: Bool) -> String {
        if monthlyHint { return oneMonth }
        let whole = max(1, Int(seconds.rounded()))
        if (27 * 86_400...31 * 86_400).contains(whole) { return oneMonth }
        if whole >= 6 * 86_400 { return sevenDay }
        if whole >= 4 * 3_600 && whole <= 6 * 3_600 { return fiveHour }
        if (20 * 3_600...28 * 3_600).contains(whole) || whole == 86_400 { return oneDay }
        if whole >= 86_400 && whole < 6 * 86_400 { return oneDay }
        return otherLimit
    }

    private static func stripModelSuffix(from label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let inner = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            let head = String(text[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty, !inner.lowercased().contains("window"), ResetAlarmCadence.durationSeconds(inner.lowercased()) == nil {
                text = head.isEmpty ? inner : head
            } else {
                text = head
            }
        }
        return text
    }

    private static func looksLikeCadenceOnly(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasSuffix(" window") {
            let head = String(lower.dropLast(" window".count))
            return cadenceFromProse(head, resetAt: nil, periodStart: nil, monthlyHint: false) != nil
        }
        return cadenceFromProse(lower, resetAt: nil, periodStart: nil, monthlyHint: false) != nil
            || ResetAlarmCadence.durationSeconds(lower) != nil
    }

    // MARK: - Muse Assist meter pairing

    /// Whether a Muse Assist window is the referral / extra allowance meter
    /// (caption `+`), not a timed cadence such as an 8-hour window.
    public static func isMuseAssistExtra(
        providerKey: String,
        windowToken: String?,
        label: String,
        resetAt: Date? = nil,
        periodStart: Date? = nil
    ) -> Bool {
        guard providerKey == "muse-assist" else { return false }
        if isExtraAllowanceLabel(label) { return true }
        let lower = label.lowercased()
        if lower.contains("additional") || lower.contains("extra") { return true }
        guard windowToken == nil else { return false }
        let cadence = standardCadence(
            windowToken: nil,
            label: label,
            resetAt: resetAt,
            periodStart: periodStart
        )
        return cadence == otherLimit
    }

    /// The Muse Assist weekly allowance meter (caption `7d`), distinct from
    /// `isMuseAssistExtra`.
    public static func isMuseAssistWeekly(
        providerKey: String,
        windowToken: String?,
        label: String,
        resetAt: Date? = nil,
        periodStart: Date? = nil
    ) -> Bool {
        guard providerKey == "muse-assist" else { return false }
        if isMuseAssistExtra(providerKey: providerKey, windowToken: windowToken, label: label,
                             resetAt: resetAt, periodStart: periodStart) { return false }
        let cadence = standardCadence(
            windowToken: windowToken,
            label: label,
            resetAt: resetAt,
            periodStart: periodStart
        )
        if cadence == sevenDay { return true }
        let lower = label.lowercased()
        let token = (windowToken ?? "").lowercased()
        return lower.contains("weekly") || token.contains("weekly") || lower.contains("free")
    }
}
