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
        /// True when the window is the extra allowance of another window on the
        /// same plan.  The label alone cannot answer that:  the label pipeline
        /// rewrites an extra allowance into the same "Other limit" copy every
        /// unknown window gets, so the identity has to travel with the bar.
        public let isExtraAllowance: Bool

        public init(cadence: String, label: String, isExtraAllowance: Bool = false) {
            self.cadence = cadence
            self.label = label
            self.isExtraAllowance = isExtraAllowance
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
    /// row needs none.
    ///
    /// The qualifier is named from the canonical cadence the caption row
    /// already prints, not from prose words:  the widget's own label pipeline
    /// rewrites a label into the hyphenated cadence copy ("7-day window"), so
    /// a matcher that looks for "weekly" in the label never matches a label
    /// the widget renders (Kody review 2026-10-21).
    ///
    /// A cadence word is only worth printing when a sibling bar shares the
    /// cadence, because on a lone bar "7d weekly" says the same thing twice.
    ///
    /// The label is consulted for the extra-allowance case alone, which is
    /// the one qualifier the label still names.
    ///
    /// `isExtraAllowance` carries the identity the label cannot:  an extra
    /// allowance is rewritten into the same "Other limit" copy every unknown
    /// window gets, so a bar that is known to be the extra allowance has to
    /// say so, or it is read as an ordinary window of its period.
    public static func barQualifier(
        forCadence cadence: String,
        label: String,
        sharesCadence: Bool,
        isExtraAllowance: Bool = false
    ) -> String {
        guard sharesCadence else { return "" }
        if isExtraAllowance || isExtraAllowanceLabel(label) { return barQualifierAdditional }
        switch cadence {
        case sevenDay: return barQualifierWeekly
        case oneMonth: return barQualifierMonthly
        case oneDay: return barQualifierDaily
        case fiveHour: return barQualifierHourly
        default: return ""
        }
    }

    /// The canonical cadence a window belongs to, used to group the bars that
    /// share one period.
    ///
    /// The window's own cadence decides the group, because that is what the
    /// caption token beside the bar prints.  The label is deliberately not
    /// handed to the canonicalizer:  the prose matcher behind it reads
    /// substrings, so a label such as "notweekly" or "notdaily" was read as a
    /// weekly or daily window before the exact-token fallback below ever ran
    /// (Kody rule 40, binding 2026-10-21).  A label resolves a group only
    /// through whole lexical tokens, below.
    ///
    /// The canonical forms the widget renders — "7-day window", "5-hour
    /// window", "1-day window", "1-month window" — name their period through
    /// whole tokens too, so a bar whose own cadence does not resolve still
    /// groups with the sibling that prints the same caption token.
    ///
    /// An extra allowance is extra capacity of the period it doubles, so it
    /// groups with that window rather than standing alone.  It carries no
    /// cadence of its own, so its label is left out of the lookup rather
    /// than collapsing the row to "Other limit".
    public static func barCadenceGroup(
        cadence: String,
        label: String,
        isExtraAllowance: Bool = false
    ) -> String {
        let canonical = standardCadence(
            windowToken: cadence,
            label: ""
        )
        if canonical != otherLimit { return canonical }
        //  An extra allowance names no period of its own, and its label is
        //  left out of the lookup:  it joins the group of the one sibling
        //  that has a period, which is what makes the owner-approved pair
        //  ("weekly" / "additional") reachable.
        if isExtraAllowance { return otherLimit }
        //  The label resolves a group only through whole lexical tokens:
        //  "weekly" names the weekly group, "notweekly" names no group at all.
        let tokens = lexicalTokens(label)
        if tokens.contains("weekly") { return sevenDay }
        if tokens.contains("monthly") || tokens.contains("billing") { return oneMonth }
        if tokens.contains("daily") { return oneDay }
        if tokens.contains("hourly") { return fiveHour }
        //  The canonical forms the widget renders still name their period:
        //  "7-day window", "5-hour window", "1-day window", "1-month window".
        //  The caption token beside the bar resolves the same form through
        //  the prose matcher, so the group has to resolve it too, or a bar
        //  that prints "7d" is grouped as "Other limit" and split from the
        //  sibling that prints the same token.
        let hasDay = tokens.contains("day") || tokens.contains("days")
        let hasHour = tokens.contains("hour") || tokens.contains("hours")
        let hasMonth = tokens.contains("month") || tokens.contains("months")
        if tokens.contains("7"), hasDay { return sevenDay }
        if tokens.contains("1"), hasDay { return oneDay }
        if tokens.contains("5"), hasHour { return fiveHour }
        if tokens.contains("1"), hasMonth { return oneMonth }
        return canonical
    }

    /// The qualifier of every bar in a caption row, in the same order.
    ///
    /// Each bar is resolved against its siblings, so a bar that shares its
    /// cadence with another bar gets the word that tells the two apart and a
    /// lone bar gets none.
    ///
    /// An extra allowance has no period of its own:  it is extra capacity of
    /// the period it doubles, and a provider that reports it without a token
    /// names no period at all.  When its own cadence resolves to nothing, it
    /// joins the group of the one sibling that has a period, which is what
    /// makes the owner-approved pair ("weekly" / "additional") reachable.
    /// The sibling has to be unambiguous, so a platform with two different
    /// periods beside it leaves the extra allowance on its own.
    public static func barQualifiers(forBars bars: [BarCaption]) -> [String] {
        var groups = bars.map {
            barCadenceGroup(
                cadence: $0.cadence,
                label: $0.label,
                isExtraAllowance: $0.isExtraAllowance
            )
        }
        for index in bars.indices where bars[index].isExtraAllowance && groups[index] == otherLimit {
            let siblingGroups = Set(
                bars.indices
                    .filter { $0 != index }
                    .map { groups[$0] }
                    .filter { $0 != otherLimit }
            )
            if siblingGroups.count == 1, let adopted = siblingGroups.first {
                groups[index] = adopted
            }
        }
        return bars.indices.map { index in
            let siblings = groups.indices.filter { $0 != index }.map { groups[$0] }
            return barQualifier(
                forCadence: groups[index],
                label: bars[index].label,
                sharesCadence: siblings.contains(groups[index]),
                isExtraAllowance: bars[index].isExtraAllowance
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

    /// Whether a window is the extra allowance of another window on the same
    /// plan.
    ///
    /// The label detector answers for labels that name the kind ("Additional
    /// allowance", "+ extra").  A provider that files its extra allowance
    /// without naming it is caught by the provider-aware check:  Muse Assist
    /// reports it as a tokenless window that resolves to no period, and the
    /// Mac popover already treats exactly that window as the extra allowance
    /// (`isMuseAssistExtra`).
    ///
    /// The identity has to be carried with the window rather than read back
    /// from its label, because the label pipeline rewrites an extra allowance
    /// into the same "Other limit" copy every unknown window gets.
    public static func isExtraAllowance(
        providerKey: String?,
        label: String,
        windowToken: String? = nil
    ) -> Bool {
        if isExtraAllowanceLabel(label) { return true }
        guard let providerKey, !providerKey.isEmpty else { return false }
        return isMuseAssistExtra(providerKey: providerKey, windowToken: windowToken, label: label)
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
        if ["1d", "24h", "daily", "day", "1-day"].contains(lower) { return oneDay }
        if ["7d", "168h", "1w", "weekly", "week", "7-day"].contains(lower) { return sevenDay }
        if ["1m", "30d", "mo", "month", "monthly", "1-month"].contains(lower) { return oneMonth }
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
