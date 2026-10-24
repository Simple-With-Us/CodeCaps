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

    /// The cadence in the words an at-cap line uses: "7-day", "5-hour".
    ///
    /// A window that already carries the canonical cadence keeps it; anything
    /// else is re-derived from its own token by exact match, so an at-cap
    /// line never says "Other limit" when the window meant something
    /// narrower, and a look-alike token such as "notweekly" can never be
    /// misread as "7-day" by a substring check.
    public static func atCapCadence(cadence: String, resetAt: Date? = nil) -> String {
        let known = [fiveHour, oneDay, sevenDay, oneMonth]
        if known.contains(cadence) { return cadence }
        // The cadence is a token, so the trailing " window" a caller may still
        // carry is stripped before the token is resolved:  "7-day window" names
        // the same period as "7-day".
        return standardCadence(windowToken: stripTrailingWindowSuffix(cadence),
                               label: "",
                               resetAt: resetAt,
                               monthlyHint: false)
    }

    /// The countdown an at-cap line quotes: the two largest non-zero units of
    /// "1d 13h", "2h 42m", "45m".  A unit that is zero is skipped rather than
    /// shown, so a countdown never reads "1d 0h".
    ///
    /// Empty when the window has no reset clock, and "due" when the reset has
    /// already passed and a fresh reading has not arrived yet.
    public static func resetCountdown(_ resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let seconds = Int(resetAt.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "due" }
        guard seconds >= 60 else { return "<1m" }
        let minutes = seconds / 60
        let units = [(minutes / 1_440, "d"), ((minutes % 1_440) / 60, "h"), (minutes % 60, "m")]
        return units.filter { $0.0 > 0 }.prefix(2).map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }

    /// The line a capped plan says instead of its bars: "7-day cap resets in
    /// 1d 13h".
    ///
    /// Shared by the Mac's menu-bar window, its PiP and the phone companion, so
    /// one plan reads the same on every surface.  Owner 2026-10-21: the phone
    /// said nothing at all when a provider was at its cap, so a capped Codex
    /// or Antigravity plan looked like any other.
    public static func atCapSummary(cadence: String, resetAt: Date?, now: Date = Date()) -> String {
        let countdown = resetCountdown(resetAt, now: now)
        guard !countdown.isEmpty, countdown != "due" else { return "\(cadence) cap" }
        return "\(cadence) cap resets in \(countdown)"
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

    // MARK: - Whose reading is this

    /// The id prefix a window carries when it is this device's own reading.
    /// The fleet copy of a Mac reading keeps the prefix, so every surface can
    /// tell an own reading from a copy of another machine's.
    public static let localDeviceWindowPrefix = "local-mac:"

    /// The producer id this app stamps its own windows with.
    public static let localProducerId = "codecaps"

    /// The producer ids this app and its legacy names stamp on their own
    /// windows.
    public static let localProducerIds = [localProducerId, "agent-bar", "local-mac"]

    /// Whether a window is this device's own reading rather than a copy of
    /// another machine's.
    ///
    /// A window that names a producer instance or a machine belongs to
    /// somebody, so it is a copy.  A window that names neither, and whose
    /// source is this app's own producer, is this device's own push coming
    /// back from the server.
    ///
    /// The owning installation's own windows carry its producer instance, so a
    /// window whose instance matches `ownInstanceId` is this device's own
    /// reading even though it names an instance.  Every fleet-sourced window
    /// names one, so without that the phone and the widget read this Mac's
    /// own expired reading as somebody else's copy and deleted it, while the
    /// Mac kept it, and the three surfaces decided differently about one
    /// payload.  The Mac asks the same question the same way
    /// (`FleetOrigin.isOwnPush` compares the instance and ignores case), so
    /// the surfaces cannot drift.
    ///
    /// `ownInstanceId` is optional so a caller that does not know the owning
    /// installation keeps the older behaviour rather than guessing:  an
    /// invented id would make somebody else's reading look like this
    /// device's own.
    public static func isOwnDeviceWindow(
        id: String,
        source: String?,
        machine: String?,
        producerInstanceId: String?,
        ownInstanceId: String? = nil
    ) -> Bool {
        // The producer instance decides before the prefix, the same
        // precedence `FleetOrigin.isOwnPush` applies:  a window carrying this
        // Mac's `local-mac:` id prefix but ANOTHER installation's producer
        // instance is a foreign copy of a same-named payload, and the two
        // surfaces must agree on one payload.  The comparison ignores case.
        let instance = (producerInstanceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let own = (ownInstanceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !instance.isEmpty, !own.isEmpty { return instance.lowercased() == own.lowercased() }
        if !instance.isEmpty { return false }
        if id.hasPrefix(localDeviceWindowPrefix) { return true }
        let named = (machine ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty { return false }
        let src = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return localProducerIds.contains(src)
    }
}

/// The one rule for "is this reading recent enough to believe", shared by
/// every surface.
///
/// The Mac's dashboard number filtered on freshness while the cap rule beside
/// it did not, so one account could read 96% in the sidebar and "7-day cap" in
/// the row next to it:  a stale window that reported an exhausted allowance
/// days ago still bound the cap (owner, Oct-22-2026).  The widget believed
/// stale windows for the same reason, and read every provider as spent.
///
/// The rule lives here, in plain Foundation, because this file is compiled
/// into the Mac app, the iOS app and the widget, and a rule the surfaces
/// share cannot drift apart.
public enum QuotaFreshnessRule {
    /// How old a reading may be before it is stale.
    ///
    /// Half an hour is the Mac's own long standing answer, and the widget's
    /// copy of it was the same number, so one threshold covers every surface.
    public static let staleAfter: TimeInterval = 30 * 60

    /// How far ahead of the clock a reading may sit before it is not believed
    /// either:  a timestamp from the future says nothing about how old the
    /// reading is.
    public static let maximumFutureSkew: TimeInterval = 5 * 60

    /// Whether a reading observed at `observedAt` is recent enough to believe
    /// at `now`.
    ///
    /// A reading with no timestamp is never fresh:  there is nothing to date
    /// it by, so nothing says it is current.
    public static func isReadingRecent(observedAt: Date?, now: Date) -> Bool {
        guard let observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age < staleAfter && age >= -maximumFutureSkew
    }

    /// Whether a window is fresh:  its reading is recent and its period has
    /// not already run out.
    ///
    /// A window whose reset has passed is waiting for a fresh reading, so its
    /// old number says nothing about the plan now, and it cannot bind a cap.
    public static func isFresh(observedAt: Date?, resetAt: Date?, now: Date) -> Bool {
        guard isReadingRecent(observedAt: observedAt, now: now) else { return false }
        if let resetAt, resetAt <= now { return false }
        return true
    }

    /// Whether a window is a dead copy of a period that has already ended.
    ///
    /// Owner 2026-10-23: the xAI row showed two 7-day windows at 0% with a
    /// "due" caption while Grok, Cursor and Grok Bot showed the same weekly
    /// allowance at 91% with a reset on 2026-10-29.  This Mac reads no xAI
    /// quota locally, so the fleet fallback filled the xAI row with copies of
    /// a period that ended days earlier, and the app printed them as live
    /// readings.
    ///
    /// A window whose reset has already passed and whose reading is no longer
    /// recent carries no live information:  it says how the plan looked before
    /// the last refresh, so no surface may present it as a reading of the
    /// plan now.
    ///
    /// It deliberately changes nothing else.  A window whose reset passed
    /// moments ago was observed moments ago as well, so it stays and keeps
    /// its `due` caption, because a period that rolls over must not blank the
    /// row beside it.  A window with no reset clock has not expired, so it
    /// stays too, and a window that is still inside its period is a reading
    /// whatever its age.
    ///
    /// A window with no observation is unverified, not dead.  The Mac's
    /// decoder maps an absent `occurredAt` to "", and the phone's wire window
    /// may carry no timestamp either, so a payload without one must keep its
    /// row:  an unverified reading is not the same thing as a reading of a
    /// period that has ended.
    public static func isDeadCopy(observedAt: Date?, resetAt: Date?, now: Date) -> Bool {
        guard let observedAt, let resetAt, resetAt <= now else { return false }
        return !isReadingRecent(observedAt: observedAt, now: now)
    }
}

/// The one rule for "may this window stand in for a plan hitting its cap",
/// shared by the Mac and the phone.
///
/// The Mac's `QuotaPlatformSection.atCapWindow()` and the phone's
/// `CompanionQuotaItem.atCapWindow()` were two implementations of one
/// question, and they answered it differently:  the phone let a provider's
/// exhausted word override a reading that said there was room left, so it
/// could announce a cap directly above a meter that read 50%.  The rule
/// lives here, in plain Foundation, because this file is compiled into the
/// Mac app, the iOS app and the widget, and a rule the two surfaces share
/// cannot drift apart.
public enum QuotaCapRule {
    /// The level at or below which a remaining reading counts as spent.
    ///
    /// Half a point rather than zero, because the interface rounds a reading to
    /// the nearest whole percent:  a window at 0.4% is drawn as "0%", so a rule
    /// that called only an exact zero spent would answer "not at cap" beside a
    /// reading of 0%.  Half a point is where the rounding happens, so the rule,
    /// the drawing and the Antigravity pool's own weekly test all mean the same
    /// thing by "at cap".
    ///
    /// This is the one number.  The Mac's Antigravity grouper reads it, the
    /// phone's model reads it, and this file is compiled into the widget as
    /// well, so no surface carries a copy of it.
    public static let spentThreshold: Double = 0.5

    /// What the cap rule needs to know about one window.
    ///
    /// The Mac's windows and the phone's windows are different types, so the
    /// rule takes the facts rather than the window, and the caller maps the
    /// answer back to its own type by `id`.
    public struct WindowFacts: Equatable {
        public let id: String
        public let remainingPercent: Double?
        public let resetAt: Date?
        /// Whether the reading is recent enough to believe, by
        /// `QuotaFreshnessRule`.  A stale window never binds a cap:  an
        /// exhausted allowance that was reported days ago says nothing about
        /// the plan now, and believing it put a "7-day cap" caption beside a
        /// sidebar that read 96% (owner, Oct-22-2026).
        ///
        /// There is no default, so a caller that has not stated the freshness
        /// of its window cannot compile.
        public let isFresh: Bool
        /// A reading that must not be believed, which only the Antigravity
        /// pool grouper knows about.
        public let isMasked: Bool
        public let isSupplementaryVideoQuota: Bool
        public let isScopedPoolAllowance: Bool
        public let isSubModelLimit: Bool

        public init(
            id: String,
            remainingPercent: Double?,
            resetAt: Date?,
            isFresh: Bool,
            isMasked: Bool = false,
            isSupplementaryVideoQuota: Bool = false,
            isScopedPoolAllowance: Bool = false,
            isSubModelLimit: Bool = false
        ) {
            self.id = id
            self.remainingPercent = remainingPercent
            self.resetAt = resetAt
            self.isFresh = isFresh
            self.isMasked = isMasked
            self.isSupplementaryVideoQuota = isSupplementaryVideoQuota
            self.isScopedPoolAllowance = isScopedPoolAllowance
            self.isSubModelLimit = isSubModelLimit
        }
    }

    /// The window that binds a plan's cap, and the one worth counting down to.
    ///
    /// A plan is capped when any of its real windows is at its cap, not when
    /// all of them are:  a weekly allowance being spent stops a plan working,
    /// whatever its shorter window still says.
    ///
    /// The rules, in the order they apply:
    ///
    /// - A window with no reading reports no cap.  When there is a reading it
    ///   decides, so a provider's exhausted word cannot override a reading that
    ///   says there is room left.
    /// - A stale window reports no cap either.  Its reading says how the plan
    ///   looked when it was taken, not how it looks now.
    /// - An allowance that sits beside the subscription rather than inside it
    ///   is skipped, and so is a masked reading.
    /// - A primary window beats a sub-model window, so a plan with a window of
    ///   its own is capped by that one.  A plan whose windows are all sub-model
    ///   windows is still capped by them.
    /// - Among the spent ones, the one that resets last binds, because the plan
    ///   stays capped until that window recovers.
    public static func bindingWindow(in windows: [WindowFacts]) -> WindowFacts? {
        bindingWindowIndex(in: windows).map { windows[$0] }
    }

    /// The index of the binding window in the same array the facts came from.
    ///
    /// A caller that built the facts from its own window list carries the
    /// choice back by position.  Re-finding the answer by id would pick the
    /// first snapshot with that id, which can be the wrong window when a
    /// section carries two snapshots with the same id.
    public static func bindingWindowIndex(in windows: [WindowFacts]) -> Int? {
        let eligible = windows.indices.filter {
            windows[$0].isFresh
                && !windows[$0].isMasked
                && !windows[$0].isSupplementaryVideoQuota
                && !windows[$0].isScopedPoolAllowance
                && windows[$0].remainingPercent != nil
        }
        let primary = eligible.filter { !windows[$0].isSubModelLimit }
        let pool = primary.isEmpty ? eligible : primary
        return pool
            .filter { isAtCap(remainingPercent: windows[$0].remainingPercent) }
            .max { (windows[$0].resetAt ?? .distantPast) < (windows[$1].resetAt ?? .distantPast) }
    }

    /// A reading bounded for display:  nil when there is no reading or it
    /// is not a finite number, otherwise clamped into 0...100.
    ///
    /// Mirrors `QuotaWindow.boundedRemainingPercent`, which does the same
    /// for the Mac's own windows.
    public static func bounded(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    /// Whether a window's allowance is spent.
    ///
    /// The reading decides whenever there is one:  a reading at or below
    /// `spentThreshold` is a spent allowance and a reading above it is
    /// headroom, even when the provider still carries an exhausted flag,
    /// which the Mac's own export never clears and which would otherwise keep
    /// reporting a cap long after the allowance came back.  With no reading at
    /// all there is nothing to believe, and the window reports no cap.
    public static func isAtCap(remainingPercent: Double?) -> Bool {
        guard let bounded = bounded(remainingPercent) else { return false }
        return bounded <= spentThreshold
    }

    /// Whether an allowance is spent, when the provider's own word and its
    /// reading can disagree.
    ///
    /// The reading decides whenever there is one:  the Mac's export never
    /// clears `isExhausted`, so a provider that still carries the flag long
    /// after the allowance came back would otherwise keep reporting a spent
    /// allowance, and the Mac and the phone would tell the owner different
    /// things about one account.  With no reading at all the provider's word is
    /// the only evidence there is, so it counts.
    ///
    /// This is the one place that decides, so no surface can carry its own
    /// version of the question.
    ///
    /// A reading exists when `bounded` can make one.  A value that is not a
    /// finite number is no reading at all, so it falls back to the provider's
    /// word rather than passing the existence check and then being judged as
    /// headroom, which is what the phone's previous `(pct ?? 100) <= 0 || flag`
    /// never did.
    public static func isExhausted(remainingPercent: Double?, providerSaysExhausted: Bool) -> Bool {
        guard let reading = bounded(remainingPercent) else { return providerSaysExhausted }
        return reading <= spentThreshold
    }

    /// The reading a row publishes for an allowance.
    ///
    /// An allowance the provider reports as gone without a figure still has to
    /// publish a reading, because the cap rule only binds a window that
    /// carries one:  a row with no percentage reports no cap at all, so the
    /// cap line never appears beside it and the countdown it should quote is
    /// lost.  A spent allowance publishes zero.
    ///
    /// The Mac's Antigravity pool grouper and the phone's own row synthesis
    /// both do this, and both do it through here, so the two cannot drift.
    ///
    /// A published reading is bounded here, so every caller publishes the same
    /// valid percentage:  the phone passes the raw wire value, and an
    /// out-of-range one would otherwise render as "150%" while the cap rule
    /// judged the same window at 100.
    public static func publishedReading(remainingPercent: Double?, allowanceSpent: Bool) -> Double? {
        if let reading = bounded(remainingPercent) { return reading }
        return allowanceSpent ? 0 : nil
    }

    /// Whether this window is a supplementary video allowance beside
    /// MiniMax's coding subscription rather than inside it.
    ///
    /// Spending one of these is not the subscription hitting its cap, so it
    /// never stands in for the subscription's own window.
    public static func isSupplementaryVideoQuota(
        providerKey: String,
        modelId: String? = nil,
        modelType: String? = nil,
        label: String = ""
    ) -> Bool {
        guard providerKey == "minimax" else { return false }
        let identity = [modelId, modelType, label].compactMap { $0 }.joined(separator: " ").lowercased()
        return identity.contains("video") || identity.contains("hailuo")
    }

    /// Whether this window is a model-specific sub-quota rather than the
    /// platform's primary shared pool quota.
    ///
    /// A sub-model window is a real limit, so it can still cap a plan, but
    /// it is not the limit the plan is sold on, and a plan with a primary
    /// window of its own is capped by that one.
    public static func isSubModelLimit(
        providerKey: String,
        id: String,
        modelId: String? = nil,
        modelType: String? = nil,
        label: String = ""
    ) -> Bool {
        if providerKey == "openai" {
            return ["local-mac:openai:code-review", "openai:code-review", "code-review"].contains(id)
                || id.hasPrefix("local-mac:openai:additional:") || id.hasPrefix("local-mac:openai:code-review:")
                || id.hasPrefix("openai:additional:") || id.hasPrefix("openai:code-review:")
                || id.hasPrefix("additional:") || id.hasPrefix("code-review:")
        }
        if providerKey == "google-antigravity" {
            if let modelId = modelId?.lowercased(), modelId.contains("argon") { return true }
            if let modelType = modelType?.lowercased(), modelType.contains("argon") { return true }
            if label.localizedCaseInsensitiveContains("argon") { return true }
            return false
        }
        if providerKey == "anthropic" {
            if let model = modelId?.lowercased(), !model.isEmpty { return true }
            let lower = label.lowercased()
            return lower.contains("fable") || lower.contains("sonnet") || lower.contains("opus") || lower.contains("haiku")
        }
        return false
    }

    /// Whether this window is a scoped allowance that sits beside the
    /// subscription rather than inside it, which is Codex's Code Review and
    /// additional rate-limit pools.
    ///
    /// A Claude or Gemini sub-model quota is not one of these:  a plan whose
    /// windows are all sub-model quotas is still capped by them.
    public static func isScopedPoolAllowance(
        providerKey: String,
        id: String,
        modelId: String? = nil,
        modelType: String? = nil,
        label: String = ""
    ) -> Bool {
        guard providerKey == "openai" else { return false }
        return isSubModelLimit(providerKey: providerKey, id: id, modelId: modelId, modelType: modelType, label: label)
    }
}
