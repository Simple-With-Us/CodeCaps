import Foundation
import SwiftUI

/// Sentence gap conforming to fleet-wide rule: two visible spaces between sentences.
public let widgetSentenceGap = "\u{00A0} "

/// Single quota allowance window represented in a widget.
public struct WidgetWindowItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let cadence: String
    public let remainingPercent: Double?
    public let absoluteRemaining: Double?
    public let resetAt: Date?
    public let isExhausted: Bool
    public let isMasked: Bool
    public let observedAt: Date?
    /// True when the window is the extra allowance of another window on the
    /// same plan.  The label cannot answer this:  an extra allowance is
    /// rewritten into the same "Other limit" copy every unknown window gets,
    /// so the identity travels with the window.
    public let isExtraAllowance: Bool
    /// Short distinguishing label for a bar when two bars share one cadence
    /// token (e.g. two "7d" bars).  "Free weekly limit" reads "weekly",
    /// "Additional tokens" reads "additional".  Empty when the row needs no
    /// qualifier.
    ///
    /// Owner 2026-10-21: the qualifier previously returned the hyphenated
    /// cadence form ("7-day", "5-hour", "1-month") and sat beside the
    /// cadence token in the same caption row, which made a `7d 7-day`
    /// duplicate on the Antigravity weekly row.  Short nouns that do not
    /// repeat the cadence are kept here, so two 7-day bars read "weekly" /
    /// "additional" (owner, 2026-10-21).
    ///
    /// The qualifier is resolved by the platform item that owns the sibling
    /// windows, because a lone bar printing "7d weekly" says the same thing
    /// twice (owner 2026-10-21).
    public let barQualifier: String

    public init(
        id: String,
        label: String,
        cadence: String,
        remainingPercent: Double?,
        resetAt: Date?,
        isExhausted: Bool = false,
        isMasked: Bool = false,
        observedAt: Date? = nil,
        barQualifier: String = "",
        isExtraAllowance: Bool = false,
        absoluteRemaining: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.cadence = cadence
        self.remainingPercent = remainingPercent
        self.absoluteRemaining = absoluteRemaining
        self.resetAt = resetAt
        self.isExhausted = isExhausted
        self.isMasked = isMasked
        self.observedAt = observedAt
        self.barQualifier = barQualifier
        self.isExtraAllowance = isExtraAllowance
    }

    /// Whether the reading is old enough that the widget says when it was
    /// taken instead of pretending it is current.
    ///
    /// The rule is the shared one, `QuotaFreshnessRule`, so the widget ages a
    /// reading the way the Mac's dashboard and the cap rule do.
    public func isStale(now: Date = Date()) -> Bool {
        guard observedAt != nil else { return false }
        return !QuotaFreshnessRule.isReadingRecent(observedAt: observedAt, now: now)
    }

    /// Whether this window's reading is recent enough to believe, by the shared
    /// rule the Mac's dashboard number and the cap rule use.
    ///
    /// A window whose reset has already passed is waiting for a fresh reading,
    /// so its old number says nothing about the plan now.
    public func isFresh(now: Date = Date()) -> Bool {
        QuotaFreshnessRule.isFresh(observedAt: observedAt, resetAt: resetAt, now: now)
    }

    /// Whether this window's reading is newer than another's, so the fresher
    /// one wins the place in a row.
    public func isFresher(than other: WidgetWindowItem, now: Date = Date()) -> Bool {
        let mineFresh = isFresh(now: now)
        let theirsFresh = other.isFresh(now: now)
        if mineFresh != theirsFresh { return mineFresh }
        return (observedAt ?? .distantPast) > (other.observedAt ?? .distantPast)
    }

    public var displayPercent: String {
        if !isMasked, remainingPercent == nil, let count = absoluteRemaining, count.isFinite {
            return "\(count.formatted(.number.precision(.fractionLength(0...2)))) left"
        }
        return WidgetPresentation.displayPercent(percent: remainingPercent, isMasked: isMasked)
    }

    public var statusColor: Color {
        WidgetPresentation.statusColor(percent: remainingPercent, isMasked: isMasked)
    }

    public func countdown(now: Date = Date()) -> String {
        WidgetPresentation.formatCountdown(resetAt: resetAt, now: now)
    }

    /// Compact cadence token for the caption under a bar: `5h`, `7d`, `1m`.
    public var cadenceToken: String {
        let token = WidgetPresentation.shortCadence(cadence: cadence, label: label)
        return token == "+" ? (isExtraAllowance ? "Extra" : "Limit") : token
    }

    /// The caption this window's bar prints.
    ///
    /// The caption carries the qualifier,  so a surface that renders it cannot leave
    /// the qualifier out:  a caption built from the window and a caption built
    /// without it are different values,  and only the first one names the sibling.
    public var caption: QuotaWindowCaption {
        QuotaWindowCaption(
            token: cadenceToken,
            qualifier: barQualifier,
            resetCaption: resetCaption()
        )
    }

    /// A copy of this window that prints the given qualifier in its caption
    /// row.  The platform item calls this once it knows the sibling windows.
    func withBarQualifier(_ qualifier: String) -> WidgetWindowItem {
        WidgetWindowItem(
            id: id,
            label: label,
            cadence: cadence,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            isExhausted: isExhausted,
            isMasked: isMasked,
            observedAt: observedAt,
            barQualifier: qualifier,
            isExtraAllowance: isExtraAllowance,
            absoluteRemaining: absoluteRemaining
        )
    }

    /// `Resets in 12d 22m`, or an empty string when the provider reports no reset.
    public func resetCaption(now: Date = Date()) -> String {
        WidgetPresentation.resetCaption(resetAt: resetAt, now: now)
    }

    /// How far through its period the window is, 0...1, or nil when the period
    /// is unknown.
    ///
    /// The shared resolver answers, the same one the Mac's caption and the
    /// Mac's marker ask, so the marker on a widget bar is drawn for the period
    /// the caption beside it names.
    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetAt else { return nil }
        guard let period = ResetAlarmCadence.resolve(token: cadence, label: label),
              let start = ResetAlarmCadence.start(of: period, endingAt: resetAt) else { return nil }
        let duration = resetAt.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        let elapsed = now.timeIntervalSince(start)
        return min(1.0, max(0.0, elapsed / duration))
    }
}

/// Overarching platform section represented in a widget.
public struct WidgetPlatformItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let providerKey: String
    public let title: String
    public let subtitle: String
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let isExhausted: Bool
    public let isMasked: Bool
    public let windows: [WidgetWindowItem]
    /// Server-supplied icon hint (Phase 2 backend manifest).  When nil the
    /// widget falls back to its built-in logo map (Phase 1 behaviour).
    public let iconHint: String?
    /// Server-supplied fallback window label (Phase 2 backend manifest).
    public let defaultWindowLabel: String?
    public let planMetadata: PlanMetadata?

    public init(
        id: String,
        providerKey: String,
        title: String,
        subtitle: String,
        remainingPercent: Double?,
        resetAt: Date?,
        isExhausted: Bool = false,
        isMasked: Bool = false,
        windows: [WidgetWindowItem] = [],
        iconHint: String? = nil,
        defaultWindowLabel: String? = nil,
        planMetadata: PlanMetadata? = nil
    ) {
        self.id = id
        self.providerKey = providerKey
        self.title = title
        self.subtitle = subtitle
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.isExhausted = isExhausted
        self.isMasked = isMasked
        self.windows = WidgetPlatformItem.windowsResolvingBarQualifiers(windows)
        self.iconHint = iconHint
        self.defaultWindowLabel = defaultWindowLabel
        self.planMetadata = planMetadata
    }

    /// Resolve every window's caption qualifier against its siblings.
    ///
    /// The qualifier is a cadence word, and a cadence word is only worth
    /// printing when another bar in the same platform shares the cadence: on
    /// a lone bar the widget printed "7d weekly", which says the same thing
    /// twice.  The resolution lives here, where the sibling windows are
    /// known, and not on the single window (owner 2026-10-21).
    private static func windowsResolvingBarQualifiers(_ windows: [WidgetWindowItem]) -> [WidgetWindowItem] {
        guard windows.count > 1 else { return windows }
        let qualifiers = QuotaWindowVocabulary.barQualifiers(
            forBars: windows.map {
                QuotaWindowVocabulary.BarCaption(
                    cadence: $0.cadence,
                    label: $0.label,
                    isExtraAllowance: $0.isExtraAllowance
                )
            }
        )
        return windows.indices.map { index in
            // A caller that named the qualifier keeps it.  The sibling
            // resolution only fills in a qualifier the caller left blank, so
            // the public `barQualifier:` parameter does not silently vanish on
            // a platform with two or more windows (Kody review 2026-10-21).
            let qualifier = qualifiers[index].isEmpty ? windows[index].barQualifier : qualifiers[index]
            return windows[index].withBarQualifier(qualifier)
        }
    }

    public var displayPercent: String {
        WidgetPresentation.displayPercent(percent: remainingPercent, isMasked: isMasked)
    }

    public var statusColor: Color {
        WidgetPresentation.statusColor(percent: remainingPercent, isMasked: isMasked)
    }

    public var accentColor: Color {
        WidgetPresentation.providerColor(providerKey: providerKey)
    }

    public func countdown(now: Date = Date()) -> String {
        WidgetPresentation.formatCountdown(resetAt: resetAt, now: now)
    }

    public func resetCaption(now: Date = Date()) -> String {
        WidgetPresentation.resetCaption(resetAt: resetAt, now: now)
    }

    /// Progress fraction in range 0.0...1.0 for gauges and progress bars.
    public var progressFraction: Double {
        if isMasked { return 0.0 }
        guard let pct = remainingPercent else { return 0.0 }
        return max(0.0, min(1.0, pct / 100.0))
    }

    public var elapsedFraction: Double? {
        windows.compactMap { $0.elapsedFraction() }.first
    }

    /// The window whose exhausted allowance caps this plan, honouring masked
    /// windows, with the soonest reset winning because that is the one that
    /// answers "when can I work again".  Mirrors
    /// `QuotaPlatformSection.atCapWindow()`.
    ///
    /// Only a fresh window may cap the plan.  A stale window said how the plan
    /// looked when the reading was taken, and the widget believed it:  every
    /// provider read "At Cap" beside bars the app had already recovered (owner,
    /// Oct-22-2026).
    public func atCapWindow(now: Date = Date()) -> WidgetWindowItem? {
        windows
            .filter { $0.isFresh(now: now) || (WidgetPresentation.isAtCap(percent: $0.remainingPercent, isExhausted: $0.isExhausted) && $0.resetAt != nil && $0.resetAt! > now) }
            .filter { !$0.isMasked && $0.remainingPercent != nil }
            .filter { WidgetPresentation.isAtCap(percent: $0.remainingPercent, isExhausted: $0.isExhausted) }
            .min { ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture) }
    }

    /// A separate extra balance remains visible even while the weekly window
    /// is spent. This does not change whether the weekly window is at cap.
    public var usableMuseExtra: WidgetWindowItem? {
        guard providerKey == "muse-assist" else { return nil }
        return windows.first { $0.isExtraAllowance && !$0.isMasked && (($0.remainingPercent ?? 0) > 0 || ($0.absoluteRemaining ?? 0) > 0) }
    }

    /// Whether this plan is at its cap on any window it reports honestly.
    /// Owner 2026-10-11: a capped plan shows no bars and says so in words.
    public var isAtCap: Bool { atCapWindow() != nil }

    /// The single window that stands in for this plan when a row shows one bar.
    ///
    /// A plan often reports two windows (Claude Code has a 5-hour and a 7-day
    /// cap), and a row is only wide enough for one bar.  The pick is explicit
    /// rather than incidental so the same rule holds on every surface:
    ///
    /// - `.mostUrgent` — the window with the least left in it, because that is
    ///   the one that will stop the owner working first.  Ties go to whichever
    ///   resets sooner.  This is the default.
    /// - `.resetsSoonest` — the window whose reset lands first, so the number
    ///   moves soonest.
    /// - `.longestRemaining` — the window with the most left, for a plan read
    ///   as headroom.
    ///
    /// A masked window can never win `.mostUrgent`, since "we cannot see this
    /// one" is not urgency.
    public func controllingWindow(_ pick: WidgetWindowPick = .mostUrgent) -> WidgetWindowItem? {
        guard !windows.isEmpty else { return nil }
        let visible = windows.filter { !$0.isMasked }
        let pool = visible.isEmpty ? windows : visible
        switch pick {
        case .mostHeadroom:
            return pool.max {
                ($0.remainingPercent ?? 100, $0.resetAt ?? .distantFuture)
                    < ($1.remainingPercent ?? 100, $1.resetAt ?? .distantFuture)
            }
        case .resetsSoonest:
            return pool.min {
                ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture)
            }
        case .mostUrgent:
            return pool.min {
                // Least remaining first; soonest reset breaks the tie.
                let lhs = $0.remainingPercent ?? 100
                let rhs = $1.remainingPercent ?? 100
                if lhs != rhs { return lhs < rhs }
                return ($0.resetAt ?? .distantFuture) < ($1.resetAt ?? .distantFuture)
            }
        }
    }

    /// The pair of windows that represent this plan when a row displays two quota bars side by side.
    ///
    /// When a plan reports two or more windows (such as a 5-hour and a 7-day cap),
    /// this returns the pair (shortest period first).  Returns nil if the plan does not have two distinct windows
    /// or if one of the windows carries no reading or reset date.
    public func dualWindows() -> (window1: WidgetWindowItem, window2: WidgetWindowItem)? {
        guard windows.count >= 2 else { return nil }
        let visible = windows.filter { !$0.isMasked && ($0.remainingPercent != nil || $0.absoluteRemaining != nil || $0.resetAt != nil) }
        guard visible.count >= 2 else { return nil }
        return (visible[0], visible[1])
    }
}

/// Pure presentation logic and parser for WidgetKit widgets.
public enum WidgetPresentation {

    /// Whether a window's allowance is spent.
    ///
    /// The widget target cannot import QuotaCore as a module (it compiles its
    /// files by path rather than linking them), but the decision is not
    /// restated here anyway:  the target compiles `QuotaWindowVocabulary.swift`,
    /// so `QuotaCapRule` is in scope and this asks the one rule that owns the
    /// question.
    ///
    /// It used to spell the comparison out here, and then the app and the
    /// widget answered differently about one payload:  the app let a healthy
    /// weekly reading outrank the export's stale `isExhausted`, while the
    /// widget still let the flag win and masked the five-hour row as "n/a"
    /// (Sentry 18329264, Kody review 2026-10-22).  Asking the rule is what
    /// keeps them in step.
    public static func isAtCap(percent: Double?, isExhausted: Bool) -> Bool {
        QuotaCapRule.isExhausted(remainingPercent: percent, providerSaysExhausted: isExhausted)
    }

    public static func displayPercent(percent: Double?, isMasked: Bool) -> String {
        if isMasked { return "n/a" }
        guard let percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    public static func statusColor(percent: Double?, isMasked: Bool) -> Color {
        if isMasked { return .secondary }
        guard let percent else { return .secondary }
        if percent <= 0 {
            return Color(red: 0.90, green: 0.25, blue: 0.25)
        }
        if percent < 20 {
            return Color(red: 0.95, green: 0.65, blue: 0.15)
        }
        return Color(red: 0.10, green: 0.70, blue: 0.45)
    }

    public static func providerColor(providerKey: String) -> Color {
        let low = providerKey.lowercased()
        if low.contains("anthropic") || low.contains("claude") {
            return Color(red: 0.85, green: 0.45, blue: 0.30)
        }
        if low.contains("openai") || low.contains("codex") {
            return Color(red: 0.10, green: 0.68, blue: 0.52)
        }
        if low.contains("cursor") {
            return Color(red: 0.20, green: 0.55, blue: 0.92)
        }
        if low.contains("minimax") {
            return Color(red: 0.40, green: 0.45, blue: 0.95)
        }
        if low.contains("antigravity") || low.contains("google-antigravity") {
            return Color(red: 0.15, green: 0.72, blue: 0.68)
        }
        if low.contains("gemini") {
            return Color(red: 0.25, green: 0.60, blue: 0.95)
        }
        if low.contains("grok") || low.contains("xai") {
            return Color(red: 0.85, green: 0.85, blue: 0.90)
        }
        return Color(red: 0.15, green: 0.72, blue: 0.68) // CodeCaps Teal
    }

    public static func formatCountdown(resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            return "\(days)d\(hours > 0 ? " \(hours)h" : "")"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h\(mins > 0 ? " \(mins)m" : "")"
        }
        return "\(minutes)m"
    }

    /// `Resets in 12d 22m`.  Two largest units at most, so a caption never
    /// grows long enough to crowd out the cadence token on the same line.
    /// Empty when there is nothing honest to say — an unknown reset stays
    /// blank rather than reading as "due".
    public static func resetCaption(resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let countdown = formatCountdown(resetAt: resetAt, now: now)
        guard !countdown.isEmpty, countdown != "due" else { return "" }
        return "Resets in " + countdown
    }

    /// Compact cadence token for the caption under a bar.  Numeric tokens only,
    /// so a 5-hour window and a 7-day window read at the same weight and the
    /// caption cannot wrap: `5h`, `7d`, `1d`, `1m`.
    ///
    /// A billing cycle is `1m`, which is what the Mac app's compact rows already
    /// show for Cursor's "Included plan", so the two surfaces agree.
    public static func shortCadence(cadence: String, label: String) -> String {
        QuotaWindowVocabulary.popoverCaption(
            windowToken: cadence,
            label: label,
            isExtraAllowance: QuotaWindowVocabulary.isExtraAllowanceLabel(label)
        )
    }

    /// Small-widget caption: `7-day · 1d 14h` (hyphenated cadence, not "remaining").
    public static func smallWidgetCaption(window: WidgetWindowItem, now: Date = Date()) -> String {
        let cadence = window.cadence.isEmpty
            ? QuotaWindowVocabulary.standardCadence(windowToken: nil, label: window.label, resetAt: window.resetAt)
            : window.cadence
        let countdown = formatCountdown(resetAt: window.resetAt, now: now)
        if window.isStale(now: now), let observed = window.observedAt {
            let updated = observed.formatted(date: .omitted, time: .shortened)
            return countdown.isEmpty ? "Updated \(updated)" : "\(cadence) · Updated \(updated)"
        }
        guard !countdown.isEmpty else { return cadence }
        return "\(cadence) · \(countdown)"
    }

    public static func parseDate(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let parsed = iso.date(from: string) { return parsed }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = frac.date(from: string) { return parsed }
        if let seconds = Double(string), seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    // MARK: - Wire Parsing

    private struct WireEnvelope: Decodable {
        let windows: [WireRawWindow]?
        let providerGroups: [WireProviderGroup]?
        /// The installation that wrote this payload.
        ///
        /// Every window the fleet sends names a producer instance, so without
        /// the payload's own id there is no way to tell this installation's
        /// reading from a copy of another machine's.  Optional on decode, so an
        /// older Mac's file still parses and the widget keeps the older
        /// behaviour rather than guessing.
        let producerInstanceId: String?
    }

    private struct WireRawWindow: Decodable {
        let id: String
        let provider: String
        let providerKey: String?
        let label: String
        let remainingPercent: Double?
        let isExhausted: Bool?
        let modelType: String?
        let modelId: String?
        let window: String?
        let resetAt: String?
        let occurredAt: String?
        let source: String?
        let machine: String?
        let producerInstanceId: String?
        let remainingUnknown: Bool?
        let absoluteRemaining: Double?
        let plan: String?
        let planName: String?
        let planMetadata: PlanMetadata?
        let planDetectedName: String?
        let planUserName: String?
        let planUserCostUsd: String?
        let planUserRenewalDateText: String?
        let planUserSubtitle: String?
        let planShowCostAndRenewal: Bool?
        let planHasMismatch: Bool?
        let planUserUpdatedAt: Double?

        private enum CodingKeys: String, CodingKey {
            case id, provider, providerKey, label, remainingPercent, isExhausted
            case modelType, modelId, window, resetAt, occurredAt, source, machine
            case producerInstanceId, remainingUnknown, absoluteRemaining, plan, planName, planMetadata
            case planDetectedName, planUserName, planUserCostUsd, planUserRenewalDateText
            case planUserSubtitle, planShowCostAndRenewal, planHasMismatch, planUserUpdatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            provider = try container.decode(String.self, forKey: .provider)
            providerKey = try container.decodeIfPresent(String.self, forKey: .providerKey)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            remainingPercent = try container.decodeIfPresent(Double.self, forKey: .remainingPercent)
            isExhausted = try container.decodeIfPresent(Bool.self, forKey: .isExhausted)
            modelType = try container.decodeIfPresent(String.self, forKey: .modelType)
            modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
            window = try container.decodeIfPresent(String.self, forKey: .window)
            resetAt = try container.decodeIfPresent(String.self, forKey: .resetAt)
            occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt)
            source = try container.decodeIfPresent(String.self, forKey: .source)
            machine = try container.decodeIfPresent(String.self, forKey: .machine)
            producerInstanceId = try container.decodeIfPresent(String.self, forKey: .producerInstanceId)
            remainingUnknown = try container.decodeIfPresent(Bool.self, forKey: .remainingUnknown)
            absoluteRemaining = try container.decodeIfPresent(Double.self, forKey: .absoluteRemaining)
            plan = try container.decodeIfPresent(String.self, forKey: .plan)
            planName = try container.decodeIfPresent(String.self, forKey: .planName)
            planMetadata = try container.decodeIfPresent(PlanMetadata.self, forKey: .planMetadata)
            planDetectedName = try container.decodeIfPresent(String.self, forKey: .planDetectedName)
            planUserName = try container.decodeIfPresent(String.self, forKey: .planUserName)
            if let costStr = try? container.decodeIfPresent(String.self, forKey: .planUserCostUsd) {
                planUserCostUsd = costStr
            } else if let costNum = try? container.decodeIfPresent(Double.self, forKey: .planUserCostUsd) {
                planUserCostUsd = String(costNum)
            } else {
                planUserCostUsd = nil
            }
            planUserRenewalDateText = try container.decodeIfPresent(String.self, forKey: .planUserRenewalDateText)
            planUserSubtitle = try container.decodeIfPresent(String.self, forKey: .planUserSubtitle)
            planShowCostAndRenewal = try container.decodeIfPresent(Bool.self, forKey: .planShowCostAndRenewal)
            planHasMismatch = try container.decodeIfPresent(Bool.self, forKey: .planHasMismatch)
            planUserUpdatedAt = try container.decodeIfPresent(Double.self, forKey: .planUserUpdatedAt)
        }

        var resolvedPlanMetadata: PlanMetadata? {
            if let planMetadata {
                return planMetadata
            }
            if planUserName != nil || planDetectedName != nil || planUserCostUsd != nil || planUserRenewalDateText != nil || planUserSubtitle != nil || planShowCostAndRenewal != nil || planHasMismatch != nil {
                var meta = PlanMetadata(detectedPlanName: planDetectedName ?? planName ?? plan, customInfo: nil, providerKey: providerKey ?? provider)
                if let planUserName { meta.userPlanName = planUserName }
                if let planUserCostUsd { meta.userCostUsd = planUserCostUsd }
                if let planUserRenewalDateText { meta.userRenewalDateText = planUserRenewalDateText }
                if let planUserSubtitle { meta.userSubtitle = planUserSubtitle }
                if let planShowCostAndRenewal { meta.showCostAndRenewal = planShowCostAndRenewal }
                if let planHasMismatch { meta.hasMismatch = planHasMismatch }
                if let planUserUpdatedAt { meta.userUpdatedAt = planUserUpdatedAt }
                return meta
            }
            if let p = planName ?? plan, !p.isEmpty {
                return PlanMetadata(detectedPlanName: p, customInfo: nil, providerKey: providerKey ?? provider)
            }
            return nil
        }
    }

    /// Mirrors the backend manifest's provider group on the wire.  Optional
    /// fields decode as absent — older envelopes keep working.  `providerLabel`
    /// falls back to `provider` exactly like the canonical
    /// `QuotaProviderGroup` decoder, so a manifest group that omits the label
    /// can never make the whole `WireEnvelope` decode throw.
    private struct WireProviderGroup: Decodable {
        let provider: String
        let providerKey: String?
        let providerLabel: String
        let via: String?
        let sortOrder: Int?
        let iconHint: String?
        let terms: WireProviderTerms?

        private enum CodingKeys: String, CodingKey {
            case provider, providerKey, providerLabel, via, sortOrder, iconHint, terms
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decode(String.self, forKey: .provider)
            providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel) ?? provider
            providerKey = try container.decodeIfPresent(String.self, forKey: .providerKey)
            via = try container.decodeIfPresent(String.self, forKey: .via)
            sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
            iconHint = try container.decodeIfPresent(String.self, forKey: .iconHint)
            terms = try container.decodeIfPresent(WireProviderTerms.self, forKey: .terms)
        }
    }

    private struct WireProviderTerms: Decodable {
        let defaultWindowLabel: String?
    }

    public static func parseSnapshot(
        data: Data,
        platformOrder: [String] = [],
        now: Date = Date()
    ) -> [WidgetPlatformItem] {
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              let rawWindows = envelope.windows, !rawWindows.isEmpty else {
            return []
        }

        var antigravityWindows: [WireRawWindow] = []
        var nonAntigravityWindows: [WireRawWindow] = []

        for w in rawWindows {
            let pKey = (w.providerKey ?? w.provider).lowercased()
            let isAntigravity = pKey.contains("antigravity")
                || w.id.lowercased().contains("antigravity")
                || w.provider.lowercased().contains("antigravity")
            if isAntigravity {
                antigravityWindows.append(w)
            } else {
                nonAntigravityWindows.append(w)
            }
        }

        var platformGroups: [String: (providerKey: String, title: String, iconHint: String?, defaultWindowLabel: String?, windows: [WireRawWindow])] = [:]
        var platformKeyOrder: [String] = []

        for w in nonAntigravityWindows {
            let (platKey, platTitle, provKey) = canonicalPlatformKey(for: w, manifest: envelope.providerGroups)
            if platformGroups[platKey] == nil {
                let manifestHint = iconHint(for: platKey, in: envelope.providerGroups)
                let defaultLabel = defaultWindowLabel(for: platKey, in: envelope.providerGroups)
                platformGroups[platKey] = (providerKey: provKey, title: platTitle, iconHint: manifestHint, defaultWindowLabel: defaultLabel, windows: [])
                platformKeyOrder.append(platKey)
            }
            platformGroups[platKey]?.windows.append(w)
        }

        var platforms: [WidgetPlatformItem] = []

        // Server-first ordering when the envelope carries a manifest: walk the
        // manifest entries first so the provider list reflects the admin's
        // current sort order, then append any future keys that arrived in the
        // windows payload but were not in the manifest.  An empty manifest
        // keeps the legacy "first-seen-wins" order (the offline-fallback path).
        let manifest = envelope.providerGroups ?? []
        let manifestKeys: [String] = manifest.isEmpty
            ? platformKeyOrder
            : manifest.compactMap { group in
                let key = canonicalManifestKey(provider: group.provider, via: group.via)
                return key.isEmpty ? nil : key
            }

        for platKey in manifestKeys {
            guard let group = platformGroups[platKey] else { continue }
            let built = buildPlatformItem(
                id: platKey,
                providerKey: group.providerKey,
                title: group.title,
                iconHint: group.iconHint,
                defaultWindowLabel: group.defaultWindowLabel,
                rawWindows: group.windows,
                now: now,
                ownInstanceId: envelope.producerInstanceId
            )
            platforms.append(built)
        }
        for platKey in platformKeyOrder where !manifestKeys.contains(platKey) {
            guard let group = platformGroups[platKey] else { continue }
            let built = buildPlatformItem(
                id: platKey,
                providerKey: group.providerKey,
                title: group.title,
                iconHint: group.iconHint,
                defaultWindowLabel: group.defaultWindowLabel,
                rawWindows: group.windows,
                now: now,
                ownInstanceId: envelope.producerInstanceId
            )
            platforms.append(built)
        }

        // Antigravity consolidation
        if !antigravityWindows.isEmpty {
            let geminiWindows = antigravityWindows.filter {
                let s = ($0.id + " " + $0.label + " " + ($0.modelType ?? "") + " " + ($0.modelId ?? "")).lowercased()
                return s.contains("gemini")
            }
            let thirdPartyWindows = antigravityWindows.filter {
                let s = ($0.id + " " + $0.label + " " + ($0.modelType ?? "") + " " + ($0.modelId ?? "")).lowercased()
                return !s.contains("gemini")
            }

            if let item = consolidateAntigravityPool(
                poolKey: "gemini",
                title: "Gemini",
                windows: geminiWindows,
                now: now,
                iconHint: iconHint(for: "google-antigravity:gemini", in: manifest) ?? "gemini-color",
                defaultLabel: defaultWindowLabel(for: "google-antigravity", in: manifest),
                ownInstanceId: envelope.producerInstanceId
            ) {
                platforms.append(item)
            }

            if let item = consolidateAntigravityPool(
                poolKey: "third-party",
                title: "3rd-Party",
                windows: thirdPartyWindows,
                now: now,
                iconHint: "antigravity",
                defaultLabel: defaultWindowLabel(for: "google-antigravity", in: manifest),
                ownInstanceId: envelope.producerInstanceId
            ) {
                platforms.append(item)
            }
        }

        // Apply platform order if specified
        if !platformOrder.isEmpty {
            var orderMap: [String: Int] = [:]
            for (idx, key) in platformOrder.enumerated() {
                orderMap[key] = idx
            }
            platforms.sort { a, b in
                let idxA = orderMap[a.id] ?? orderMap[a.providerKey] ?? 999
                let idxB = orderMap[b.id] ?? orderMap[b.providerKey] ?? 999
                if idxA != idxB { return idxA < idxB }
                return a.title < b.title
            }
        }

        return platforms
    }

    /// Build a single WidgetPlatformItem from a window group + manifest hints.
    private static func buildPlatformItem(
        id: String,
        providerKey: String,
        title: String,
        iconHint: String?,
        defaultWindowLabel: String?,
        rawWindows: [WireRawWindow],
        now: Date,
        ownInstanceId: String? = nil
    ) -> WidgetPlatformItem {
        var providerPlanMetadata: PlanMetadata? = nil
        for w in rawWindows {
            if let meta = w.resolvedPlanMetadata {
                if providerPlanMetadata == nil {
                    providerPlanMetadata = meta
                } else {
                    if providerPlanMetadata?.userPlanName == nil { providerPlanMetadata?.userPlanName = meta.userPlanName }
                    if providerPlanMetadata?.userCostUsd == nil { providerPlanMetadata?.userCostUsd = meta.userCostUsd }
                    if providerPlanMetadata?.userRenewalDateText == nil { providerPlanMetadata?.userRenewalDateText = meta.userRenewalDateText }
                    if providerPlanMetadata?.userSubtitle == nil { providerPlanMetadata?.userSubtitle = meta.userSubtitle }
                    if providerPlanMetadata?.detectedPlanName == nil { providerPlanMetadata?.detectedPlanName = meta.detectedPlanName }
                    if providerPlanMetadata?.showCostAndRenewal == nil { providerPlanMetadata?.showCostAndRenewal = meta.showCostAndRenewal }
                }
            }
        }

        var windowByCadence: [String: WidgetWindowItem] = [:]
        var cadenceOrder: [String] = []
        var childWindows: [WidgetWindowItem] = []

        // A copy of a period that ended before the last refresh is not a
        // reading, so it never becomes a row here either.  The rule is the
        // shared one, the same the Mac and the phone ask, so the three
        // surfaces cannot drift apart, and it is asked with the reading's own
        // observation time.  It only judges copies:  this Mac's own reading
        // keeps its row, so an expired one greys out instead of vanishing.
        let liveWindows = rawWindows.filter { w in
            let lowId = w.id.lowercased()
            let lowLabel = w.label.lowercased()
            if lowId.hasSuffix(":plan-metadata") || lowLabel == "plan details" {
                return false
            }
            if (w.remainingUnknown == true || lowLabel.contains("plan details"))
                && w.remainingPercent == nil
                && w.absoluteRemaining == nil
                && parseDate(from: w.resetAt) == nil
                && !QuotaWindowVocabulary.isExtraAllowanceLabel(w.label) {
                return false
            }
            if QuotaWindowVocabulary.isOwnDeviceWindow(id: w.id,
                                                        source: w.source,
                                                        machine: w.machine,
                                                        producerInstanceId: w.producerInstanceId,
                                                        ownInstanceId: ownInstanceId) {
                return true
            }
            return !QuotaFreshnessRule.isDeadCopy(observedAt: parseDate(from: w.occurredAt),
                                                  resetAt: parseDate(from: w.resetAt),
                                                  now: now)
        }

        for w in liveWindows {
            let parsedReset = parseDate(from: w.resetAt)
            let observed = parseDate(from: w.occurredAt)
            let cadence = formatCadence(w.label, window: w.window, resetAt: parsedReset)
            let pct = w.remainingPercent
            // The one shared rule decides, as it does on the phone and on the
            // Mac:  a reading outranks the export's stale exhausted word, and
            // the word is the fallback for a window that reports no figure.
            let exhausted = QuotaCapRule.isExhausted(remainingPercent: pct,
                                                      providerSaysExhausted: w.isExhausted ?? false)
            let displayLabel = QuotaWindowVocabulary.windowLabel(
                windowToken: w.window,
                existingLabel: w.label.isEmpty ? cadence : w.label,
                resetAt: parsedReset
            )
            //  The extra-allowance identity is read off the wire label, not
            //  off the display label:  the display copy rewrites an extra
            //  allowance into the same "Other limit" text every unknown
            //  window gets, so by the time the qualifier is resolved the
            //  difference is gone.
            let isExtraAllowance = QuotaWindowVocabulary.isExtraAllowance(
                providerKey: providerKey,
                label: w.label,
                windowToken: w.window
            )

            let item = WidgetWindowItem(
                id: w.id,
                label: displayLabel,
                cadence: cadence,
                remainingPercent: pct,
                resetAt: parsedReset,
                isExhausted: exhausted,
                isMasked: false,
                observedAt: observed,
                isExtraAllowance: isExtraAllowance,
                absoluteRemaining: w.absoluteRemaining
            )

            // One window per cadence, and the freshest one.  The payload
            // carries a fleet copy beside the local window, and the fleet copy
            // is often days old, so taking the first one in payload order let a
            // stale copy win and the widget show figures the app had already
            // replaced (owner, Oct-22-2026).
            let cadenceKey = cadence.lowercased()
            if let current = windowByCadence[cadenceKey] {
                if item.isFresher(than: current, now: now) {
                    windowByCadence[cadenceKey] = item
                }
            } else {
                cadenceOrder.append(cadenceKey)
                windowByCadence[cadenceKey] = item
            }
        }
        childWindows = cadenceOrder.compactMap { windowByCadence[$0] }

        // Standardize cadence order: shorter periods (e.g. 5-hour) precede longer periods (e.g. weekly).
        childWindows.sort { left, right in
            let lPeriod = ResetAlarmCadence.periodSeconds(token: left.cadence, label: left.label) ?? 86400
            let rPeriod = ResetAlarmCadence.periodSeconds(token: right.cadence, label: right.label) ?? 86400
            if lPeriod != rPeriod {
                return lPeriod < rPeriod
            }
            return left.id < right.id
        }

        // The headline reads the fresh windows, the way the Mac's dashboard row
        // does:  a stale reading says how the plan looked when it was taken.
        // The last known reading stands in when nothing is fresh, so a row with
        // no live reading still shows what it last knew, beside the time it
        // was taken.
        let freshWindows = childWindows.filter { $0.isFresh(now: now) }
        let freshPercent = freshWindows.compactMap(\.remainingPercent).min()
        let lastKnownPercent = childWindows.compactMap(\.remainingPercent).min()
        // Only a fresh window may cap the plan.
        let atCap = freshWindows.first {
            WidgetPresentation.isAtCap(percent: $0.remainingPercent, isExhausted: $0.isExhausted)
        }
        let controllingPct = atCap?.remainingPercent ?? freshPercent ?? lastKnownPercent
        let isExhausted = atCap != nil
        let nearestReset = childWindows.compactMap(\.resetAt).filter { $0 > now }.min()
            ?? childWindows.compactMap(\.resetAt).min()

        let automaticPlan = rawWindows.compactMap(\.planName).first(where: { !$0.isEmpty })
            ?? rawWindows.compactMap(\.plan).first(where: { !$0.isEmpty })
            ?? providerPlanMetadata?.detectedPlanName
        let resolvedSubtitle = WidgetPlatformDisplay.subtitle(
            planMetadata: providerPlanMetadata,
            automaticPlanName: automaticPlan,
            poolSubtitle: nil,
            providerKey: providerKey
        )
        let subtitle: String
        if let resolvedSubtitle, !resolvedSubtitle.isEmpty {
            subtitle = resolvedSubtitle
        } else if let firstCadence = childWindows.first?.cadence, !firstCadence.isEmpty {
            subtitle = firstCadence
        } else if let defaultWindowLabel, !defaultWindowLabel.isEmpty {
            subtitle = defaultWindowLabel
        } else {
            subtitle = "Subscription Plan"
        }

        return WidgetPlatformItem(
            id: id,
            providerKey: providerKey,
            title: title,
            subtitle: subtitle,
            remainingPercent: controllingPct,
            resetAt: nearestReset,
            isExhausted: isExhausted,
            isMasked: false,
            windows: childWindows,
            iconHint: iconHint,
            defaultWindowLabel: defaultWindowLabel,
            planMetadata: providerPlanMetadata
        )
    }

    private static func consolidateAntigravityPool(
        poolKey: String,
        title: String,
        windows: [WireRawWindow],
        now: Date,
        iconHint: String? = nil,
        defaultLabel: String? = nil,
        ownInstanceId: String? = nil
    ) -> WidgetPlatformItem? {
        guard !windows.isEmpty else { return nil }
        // A copy of a period that ended before the last refresh is not a
        // reading, so it never joins the pool.  The rule is the shared one,
        // asked with the reading's own observation time, and it only judges
        // copies:  this Mac's own reading keeps the pool alive, so an expired
        // one greys out instead of vanishing.
        let liveWindows = windows.filter { w in
            if QuotaWindowVocabulary.isOwnDeviceWindow(id: w.id,
                                                        source: w.source,
                                                        machine: w.machine,
                                                        producerInstanceId: w.producerInstanceId,
                                                        ownInstanceId: ownInstanceId) {
                return true
            }
            return !QuotaFreshnessRule.isDeadCopy(observedAt: parseDate(from: w.occurredAt),
                                                  resetAt: parseDate(from: w.resetAt),
                                                  now: now)
        }
        // A pool whose copies have all expired still renders:  it keeps the
        // windows it had, so the row survives rather than disappearing.
        let windows = liveWindows.isEmpty ? windows : liveWindows
        guard !windows.isEmpty else { return nil }

        var childWindows: [WidgetWindowItem] = []
        var fiveHourWin: WireRawWindow?
        var weeklyWin: WireRawWindow?

        /// Whether a window's reading is recent enough to believe, by the
        /// shared rule.
        func isFresh(_ window: WireRawWindow?) -> Bool {
            guard let window else { return false }
            return QuotaFreshnessRule.isFresh(observedAt: parseDate(from: window.occurredAt),
                                              resetAt: parseDate(from: window.resetAt),
                                              now: now)
        }

        /// The freshest window wins, not the smallest reading.  The payload
        /// carries pool copies that are days old and read zero, and taking the
        /// smallest reading picked those, so the widget said the pool was spent
        /// while the app had already recovered it (owner, Oct-22-2026).
        func isFresher(_ candidate: WireRawWindow, than current: WireRawWindow?) -> Bool {
            guard let current else { return true }
            let candidateFresh = isFresh(candidate)
            let currentFresh = isFresh(current)
            if candidateFresh != currentFresh { return candidateFresh }
            return (parseDate(from: candidate.occurredAt) ?? .distantPast)
                > (parseDate(from: current.occurredAt) ?? .distantPast)
        }

        for w in windows {
            let label = (w.label + " " + (w.window ?? "")).lowercased()
            if label.contains("5h") || label.contains("5-hour") {
                if isFresher(w, than: fiveHourWin) {
                    fiveHourWin = w
                }
            } else if label.contains("7d") || label.contains("weekly") || label.contains("1w") {
                if isFresher(w, than: weeklyWin) {
                    weeklyWin = w
                }
            }
        }

        let weeklyPct = weeklyWin?.remainingPercent
        // Only a fresh window may spend the pool.  A pool copy that is days old
        // is not evidence about the pool now.
        let weeklyExhausted = isFresh(weeklyWin)
            && QuotaCapRule.isExhausted(remainingPercent: weeklyPct,
                                        providerSaysExhausted: weeklyWin?.isExhausted ?? false)

        if let f = fiveHourWin {
            let reset = parseDate(from: f.resetAt)
            let fiveHourSpent = isFresh(fiveHourWin)
                && QuotaCapRule.isExhausted(remainingPercent: f.remainingPercent,
                                            providerSaysExhausted: f.isExhausted ?? false)
            childWindows.append(WidgetWindowItem(
                id: f.id,
                label: "5-hour window",
                cadence: "5h",
                // The reading the phone would publish for the same window, so
                // a spent allowance the payload left without a figure still
                // carries one here and its cap line survives.
                remainingPercent: QuotaCapRule.publishedReading(remainingPercent: f.remainingPercent,
                                                                allowanceSpent: fiveHourSpent),
                resetAt: reset,
                isExhausted: fiveHourSpent,
                isMasked: weeklyExhausted,
                observedAt: parseDate(from: f.occurredAt)
            ))
        }

        if let w = weeklyWin {
            let reset = parseDate(from: w.resetAt)
            childWindows.append(WidgetWindowItem(
                id: w.id,
                label: "Weekly cap",
                cadence: "Weekly",
                // A weekly the provider reports as gone without a figure
                // publishes zero here too, so the widget carries the same
                // reading as the phone and the Mac for one account.
                remainingPercent: QuotaCapRule.publishedReading(remainingPercent: w.remainingPercent,
                                                                allowanceSpent: weeklyExhausted),
                resetAt: reset,
                isExhausted: weeklyExhausted,
                isMasked: false,
                observedAt: parseDate(from: w.occurredAt)
            ))
        }

        let validPercents = [fiveHourWin?.remainingPercent, weeklyWin?.remainingPercent].compactMap { $0 }
        // The headline reads the fresh windows, the way the Mac's dashboard row
        // does, and falls back to the last known reading when nothing is fresh.
        let freshPercents = [
            fiveHourWin.flatMap { isFresh($0) ? $0.remainingPercent : nil },
            weeklyWin.flatMap { isFresh($0) ? $0.remainingPercent : nil }
        ].compactMap { $0 }
        let controllingPct = freshPercents.min() ?? validPercents.min() ?? windows.compactMap(\.remainingPercent).min()
        // The pool rule the phone applies:  a weekly the provider reports as
        // spent spends the pool even when the five-hour window beside it still
        // reports a healthy reading, and the controlling reading decides every
        // other case.
        let isExhausted = weeklyExhausted || QuotaCapRule.isAtCap(remainingPercent: freshPercents.min())

        let nearestReset = childWindows.compactMap(\.resetAt).filter { $0 > now }.min()
            ?? childWindows.compactMap(\.resetAt).min()

        let poolSub = poolKey == "gemini" ? "Gemini" : "Third-Party"
        let subtitle = WidgetPlatformDisplay.subtitle(
            planMetadata: nil,
            automaticPlanName: nil,
            poolSubtitle: poolSub,
            providerKey: "google-antigravity"
        ) ?? (poolKey == "gemini" ? "Gemini Models" : "Third-Party Models")

        return WidgetPlatformItem(
            id: "antigravity-\(poolKey)",
            providerKey: "google-antigravity",
            title: title,
            subtitle: subtitle,
            remainingPercent: controllingPct,
            resetAt: nearestReset,
            isExhausted: isExhausted,
            isMasked: false,
            windows: childWindows,
            iconHint: iconHint,
            defaultWindowLabel: defaultLabel,
            planMetadata: nil
        )
    }

    private static func canonicalPlatformKey(
        for raw: WireRawWindow,
        manifest: [WireProviderGroup]? = nil
    ) -> (key: String, title: String, providerKey: String) {
        let legacy = canonicalPlatformKeyLegacy(for: raw)
        // Server-first: when the manifest lists this provider, its label
        // wins.  Generic over the manifest's keys, so a provider added purely
        // via the backend manifest gets its server label with no app change.
        // (The manifest lookup is by the window's canonical key — never by
        // substring — so unrelated windows can never collapse onto one entry.)
        if let manifest,
           let group = manifest.first(where: {
               canonicalManifestKey(provider: $0.provider, via: $0.via) == legacy.key
           }) {
            let label = group.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = WidgetPlatformDisplay.title(
                canonicalKey: legacy.key,
                manifestProviderLabel: label.isEmpty ? nil : label,
                wireProvider: raw.provider
            )
            return (legacy.key, title, legacy.providerKey)
        }
        let title = WidgetPlatformDisplay.title(
            canonicalKey: legacy.key,
            manifestProviderLabel: legacy.title,
            wireProvider: raw.provider
        )
        return (legacy.key, title, legacy.providerKey)
    }

    /// The pre-manifest hardcoded mapping.  Kept as the offline fallback and
    /// as the canonical-key computation the manifest lookup keys off.
    private static func canonicalPlatformKeyLegacy(for raw: WireRawWindow) -> (key: String, title: String, providerKey: String) {
        let pKey = (raw.providerKey ?? raw.provider).lowercased()
        let prov = raw.provider.lowercased()
        let id = raw.id.lowercased()

        if pKey.contains("anthropic") || prov.contains("anthropic") || prov.contains("claude") {
            return ("anthropic", "Claude Code", "anthropic")
        }
        if pKey.contains("openai") || prov.contains("openai") || prov.contains("codex") {
            return ("openai", "Codex", "openai")
        }
        if pKey.contains("minimax") || prov.contains("minimax") {
            return ("minimax", "MiniMax", "minimax")
        }
        if pKey.contains("muse-assist") || prov.contains("muse-assist") || prov.contains("muse assist") || id.contains("assist") {
            return ("muse-assist", "Muse Assist", "muse-assist")
        }
        if pKey.contains("muse-code") || prov.contains("muse-code") || prov.contains("muse code") || id.contains("code") {
            return ("muse-code", "Muse Code", "muse-code")
        }
        if pKey.contains("muse") || prov.contains("muse") {
            return ("muse-assist", "Muse Assist", "muse-assist")
        }
        if pKey.contains("grok-bot") || prov.contains("grok-bot") || prov.contains("grok bot") || id.contains("grok-bot") {
            return ("grok-bot", "Grok Bot", "grok-bot")
        }
        if pKey.contains("cursor") || prov.contains("cursor") {
            return ("cursor", "Cursor", "cursor")
        }
        if pKey.contains("grok") || prov.contains("grok") || pKey.contains("xai") || prov.contains("xai") {
            return ("xai", "Grok", "xai")
        }
        let fallbackKey = (raw.providerKey ?? raw.provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = fallbackKey.isEmpty ? "other" : fallbackKey
        let title = WidgetPlatformDisplay.title(canonicalKey: key, wireProvider: raw.provider)
        return (key, title, fallbackKey.isEmpty ? key : fallbackKey)
    }

    /// Mirror of `QuotaProviders.canonicalKey` for the wire manifest.  Kept
    /// local because the widget bundle cannot import the Mac-side helpers.
    static func canonicalManifestKey(provider: String, via: String?) -> String {
        let trimmedVia = via?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if trimmedVia == "antigravity" { return "google-antigravity" }
        let raw = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: String] = [
            "anthropic": "anthropic", "claude": "anthropic", "claude-code": "anthropic", "claude.ai": "anthropic",
            "openai": "openai", "openai-codex": "openai", "codex": "openai",
            "google": "google-antigravity", "google-antigravity": "google-antigravity", "antigravity": "google-antigravity", "antigravity-cli": "google-antigravity", "gemini": "google-antigravity",
            "cursor": "cursor",
            "xai": "xai", "grok": "xai", "grok-build": "xai",
            "grok-bot": "grok-bot", "grok bot": "grok-bot", "grokbot": "grok-bot",
            "minimax": "minimax", "minimax-code": "minimax",
            "kimi": "kimi", "moonshot": "kimi", "moonshot-ai": "kimi",
            "gemini-cli": "gemini-cli",
            "copilot": "github-copilot", "github-copilot": "github-copilot", "github_copilot": "github-copilot",
            "windsurf": "windsurf", "codeium": "windsurf",
        ]
        return aliases[raw] ?? raw
    }

    /// The manifest's `iconHint` for the canonicalized key, if any.
    private static func iconHint(for canonicalKey: String, in manifest: [WireProviderGroup]?) -> String? {
        guard let manifest else { return nil }
        return manifest.first { canonicalManifestKey(provider: $0.provider, via: $0.via) == canonicalKey }?.iconHint
    }

    /// The manifest's `terms.defaultWindowLabel` for the canonicalized key.
    private static func defaultWindowLabel(for canonicalKey: String, in manifest: [WireProviderGroup]?) -> String? {
        guard let manifest else { return nil }
        return manifest.first { canonicalManifestKey(provider: $0.provider, via: $0.via) == canonicalKey }?.terms?.defaultWindowLabel
    }

    public static func formatCadence(_ label: String, window: String? = nil, resetAt: Date? = nil) -> String {
        QuotaWindowVocabulary.standardCadence(
            windowToken: window,
            label: label,
            resetAt: resetAt,
            periodStart: nil
        )
    }

    // MARK: - Placeholder Data for Previews and Gallery

    public static var placeholders: [WidgetPlatformItem] {
        let now = Date()
        return [
            WidgetPlatformItem(
                id: "anthropic",
                providerKey: "anthropic",
                title: "Claude Code",
                subtitle: "5h · 7d",
                remainingPercent: 82.0,
                resetAt: now.addingTimeInterval(3600 * 3 + 720),
                isExhausted: false,
                isMasked: false,
                windows: [
                    WidgetWindowItem(
                        id: "claude-5h",
                        label: "5-hour window",
                        cadence: "5h",
                        remainingPercent: 82.0,
                        resetAt: now.addingTimeInterval(3600 * 3 + 720)
                    ),
                    WidgetWindowItem(
                        id: "claude-7d",
                        label: "7-day window",
                        cadence: "7d",
                        remainingPercent: 64.0,
                        resetAt: now.addingTimeInterval(3600 * 24 * 4)
                    )
                ]
            ),
            WidgetPlatformItem(
                id: "cursor",
                providerKey: "cursor",
                title: "Cursor",
                subtitle: "Monthly",
                remainingPercent: 45.0,
                resetAt: now.addingTimeInterval(3600 * 24 * 12),
                isExhausted: false,
                isMasked: false,
                windows: [
                    WidgetWindowItem(
                        id: "cursor-monthly",
                        label: "Monthly window",
                        cadence: "Monthly",
                        remainingPercent: 45.0,
                        resetAt: now.addingTimeInterval(3600 * 24 * 12)
                    )
                ]
            ),
            WidgetPlatformItem(
                id: "minimax",
                providerKey: "minimax",
                title: "MiniMax",
                subtitle: "5h · 1d",
                remainingPercent: 91.0,
                resetAt: now.addingTimeInterval(3600 * 18),
                isExhausted: false,
                isMasked: false,
                windows: [
                    WidgetWindowItem(
                        id: "minimax-daily",
                        label: "Daily cap",
                        cadence: "Daily",
                        remainingPercent: 91.0,
                        resetAt: now.addingTimeInterval(3600 * 18)
                    )
                ]
            ),
            WidgetPlatformItem(
                id: "antigravity-gemini",
                providerKey: "google-antigravity",
                title: "Gemini",
                subtitle: "5h · 7d",
                remainingPercent: 74.0,
                resetAt: now.addingTimeInterval(3600 * 24 * 5),
                isExhausted: false,
                isMasked: false,
                windows: [
                    WidgetWindowItem(
                        id: "antigravity-gemini-5h",
                        label: "5-hour window",
                        cadence: "5h",
                        remainingPercent: 74.0,
                        resetAt: now.addingTimeInterval(3600 * 4)
                    ),
                    WidgetWindowItem(
                        id: "antigravity-gemini-weekly",
                        label: "Weekly cap",
                        cadence: "Weekly",
                        remainingPercent: 88.0,
                        resetAt: now.addingTimeInterval(3600 * 24 * 5)
                    )
                ]
            )
        ]
    }
}
