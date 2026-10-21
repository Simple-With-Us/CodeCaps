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
    /// else is re-derived from its own label, so an at-cap line never says
    /// "Other limit" when the window meant something narrower.
    public static func atCapCadence(cadence: String, resetAt: Date? = nil) -> String {
        let known = [fiveHour, oneDay, sevenDay, oneMonth]
        if known.contains(cadence) { return cadence }
        return standardCadence(windowToken: nil, label: cadence, resetAt: resetAt, monthlyHint: false)
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
