import Foundation
import Security
import SwiftUI
import UserNotifications

#if os(iOS)
import UIKit
#endif

public struct CompanionInAppAlert: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let kind: UsageAlertKind
    public let sourceInstanceId: String?
}

/// Whether the companion shows only this device's readings or every synced source.
public enum CompanionSourceScope: String, CaseIterable, Identifiable, Sendable {
    case thisIPhone = "This iPhone"
    case allSources = "All Sources"

    public var id: String { rawValue }

    /// The label the source-scope picker shows.
    ///
    /// The stored raw value still says "This iPhone" because that is what it
    /// always was and it is what a saved preference is keyed on.  The app
    /// ships for iPhone and iPad, and the label on screen has to name the
    /// device the reader is actually holding.
    public var displayTitle: String {
        title(for: Self.currentDeviceFamily)
    }

    /// The device word the picker label uses: "iPhone", "iPad" or "Mac".
    public static var currentDeviceFamily: String {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        return "Mac"
        #endif
    }

    /// The label for a given device family.
    ///
    /// It is separate from the idiom lookup so the wording can be checked
    /// without a device.
    public func title(for family: String) -> String {
        switch self {
        case .thisIPhone: return "This \(family)"
        case .allSources: return rawValue
        }
    }
}
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Formats dates from ISO8601 strings or timestamp numbers.
public enum CompanionDateFormatter {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let parsed = isoFormatter.date(from: string) { return parsed }
        if let parsed = fractionalFormatter.date(from: string) { return parsed }
        if let seconds = Double(string), seconds.isFinite {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

/// An individual quota window or time period within a platform.
public struct CompanionWindowItem: Identifiable, Codable, Equatable {
    public let id: String
    public let label: String
    public let cadence: String
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let source: String?
    public let via: String?
    public let isDuplicateSource: Bool
    public let isExhausted: Bool
    public let isMasked: Bool
    /// Whether this window is a supplementary video allowance beside the
    /// subscription rather than inside it.
    ///
    /// Computed with the shared `QuotaCapRule`, so the phone skips exactly the
    /// windows the Mac skips and the two surfaces cannot disagree about which
    /// window is allowed to stand in for a plan hitting its cap.
    public let isSupplementaryVideoQuota: Bool
    /// Whether this window is a scoped pool allowance beside the subscription.
    public let isScopedPoolAllowance: Bool
    /// Whether this window is a model-specific sub-quota rather than the
    /// platform's primary shared pool quota.
    public let isSubModelLimit: Bool
    public let absoluteRemaining: Double?
    public let absoluteLimit: Double?
    public let quotaUnit: String?
    /// When this feed last reported the window (wire `reportedAt`, else `occurredAt`).
    public let reportedAt: Date?
    public let producerInstanceId: String?
    /// Normalized allowance key used to pair primary and mirror windows.
    public let normalizedWindowKey: String

    public init(
        id: String,
        label: String,
        cadence: String,
        remainingPercent: Double?,
        resetAt: Date?,
        source: String? = nil,
        via: String? = nil,
        isDuplicateSource: Bool = false,
        isExhausted: Bool = false,
        isMasked: Bool = false,
        isSupplementaryVideoQuota: Bool = false,
        isScopedPoolAllowance: Bool = false,
        isSubModelLimit: Bool = false,
        absoluteRemaining: Double? = nil,
        absoluteLimit: Double? = nil,
        quotaUnit: String? = nil,
        reportedAt: Date? = nil,
        normalizedWindowKey: String = "",
        producerInstanceId: String? = nil
    ) {
        self.id = id
        self.label = label
        self.cadence = cadence
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.source = source
        self.via = via
        self.isDuplicateSource = isDuplicateSource
        self.isExhausted = isExhausted
        self.isMasked = isMasked
        self.isSupplementaryVideoQuota = isSupplementaryVideoQuota
        self.isScopedPoolAllowance = isScopedPoolAllowance
        self.isSubModelLimit = isSubModelLimit
        self.absoluteRemaining = absoluteRemaining
        self.absoluteLimit = absoluteLimit
        self.quotaUnit = quotaUnit
        self.reportedAt = reportedAt
        self.producerInstanceId = producerInstanceId
        self.normalizedWindowKey = normalizedWindowKey.isEmpty
            ? Self.fallbackNormalizedWindowKey(cadence: cadence, label: label, resetAt: resetAt)
            : normalizedWindowKey
    }

    static func fallbackNormalizedWindowKey(cadence: String, label: String, resetAt: Date?) -> String {
        QuotaWindowVocabulary.standardCadence(
            windowToken: cadence,
            label: label,
            resetAt: resetAt
        ).lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, cadence, remainingPercent, resetAt, source, via
        case isDuplicateSource, isExhausted, isMasked
        case isSupplementaryVideoQuota, isScopedPoolAllowance, isSubModelLimit
        case absoluteRemaining, absoluteLimit, quotaUnit
        case reportedAt, observedAt, normalizedWindowKey, producerInstanceId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        cadence = try container.decode(String.self, forKey: .cadence)
        producerInstanceId = try container.decodeIfPresent(String.self, forKey: .producerInstanceId)
        remainingPercent = try container.decodeIfPresent(Double.self, forKey: .remainingPercent)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        via = try container.decodeIfPresent(String.self, forKey: .via)
        isDuplicateSource = try container.decodeIfPresent(Bool.self, forKey: .isDuplicateSource) ?? false
        isExhausted = try container.decodeIfPresent(Bool.self, forKey: .isExhausted) ?? false
        isMasked = try container.decodeIfPresent(Bool.self, forKey: .isMasked) ?? false
        isSupplementaryVideoQuota = try container.decodeIfPresent(Bool.self, forKey: .isSupplementaryVideoQuota) ?? false
        isScopedPoolAllowance = try container.decodeIfPresent(Bool.self, forKey: .isScopedPoolAllowance) ?? false
        isSubModelLimit = try container.decodeIfPresent(Bool.self, forKey: .isSubModelLimit) ?? false
        absoluteRemaining = try container.decodeIfPresent(Double.self, forKey: .absoluteRemaining)
        absoluteLimit = try container.decodeIfPresent(Double.self, forKey: .absoluteLimit)
        quotaUnit = try container.decodeIfPresent(String.self, forKey: .quotaUnit)
        reportedAt = try container.decodeIfPresent(Date.self, forKey: .reportedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .observedAt)
        let decodedKey = try container.decodeIfPresent(String.self, forKey: .normalizedWindowKey) ?? ""
        normalizedWindowKey = decodedKey.isEmpty
            ? Self.fallbackNormalizedWindowKey(cadence: cadence, label: label, resetAt: resetAt)
            : decodedKey
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(cadence, forKey: .cadence)
        try container.encodeIfPresent(remainingPercent, forKey: .remainingPercent)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(via, forKey: .via)
        try container.encode(isDuplicateSource, forKey: .isDuplicateSource)
        try container.encode(isExhausted, forKey: .isExhausted)
        try container.encode(isMasked, forKey: .isMasked)
        try container.encode(isSupplementaryVideoQuota, forKey: .isSupplementaryVideoQuota)
        try container.encode(isScopedPoolAllowance, forKey: .isScopedPoolAllowance)
        try container.encode(isSubModelLimit, forKey: .isSubModelLimit)
        try container.encodeIfPresent(absoluteRemaining, forKey: .absoluteRemaining)
        try container.encodeIfPresent(absoluteLimit, forKey: .absoluteLimit)
        try container.encodeIfPresent(quotaUnit, forKey: .quotaUnit)
        try container.encodeIfPresent(reportedAt, forKey: .reportedAt)
        try container.encodeIfPresent(producerInstanceId, forKey: .producerInstanceId)
        try container.encode(normalizedWindowKey, forKey: .normalizedWindowKey)
    }

    /// Whether `reportedAt` is within the disagreement alert freshness window.
    public func isFreshForSourceDiscrepancy(now: Date = Date()) -> Bool {
        FleetSourceDisagreement.isReportedWithinAlertWindow(reportedAt, now: now)
    }

    public var isMacCodeCapsReading: Bool {
        FleetMacReading.isMacCodeCapsReading(id: id, source: source, via: via)
    }

    /// Compact cadence beside a meter bar (`5h`, `7d`, `1m`, `+`), matching Mac Glance.
    public var meterCaption: String {
        QuotaWindowVocabulary.popoverCaption(
            windowToken: cadence.isEmpty ? nil : cadence,
            label: label,
            resetAt: resetAt,
            monthlyHint: label.lowercased().contains("plan") || cadence.lowercased().contains("plan")
        )
    }

    /// The cadence in the words an at-cap line uses: "7-day", "5-hour".  The
    /// window already carries the canonical cadence, so this only re-derives it
    /// when a window arrived with something else.
    public var atCapCadenceLabel: String {
        QuotaWindowVocabulary.atCapCadence(cadence: cadence, resetAt: resetAt)
    }

    public var displayPercent: String {
        if isMasked { return "n/a" }
        guard let remainingPercent else { return "—" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    public var statusColor: Color {
        if isMasked { return .secondary }
        guard let remainingPercent else { return .secondary }
        if remainingPercent <= 0 { return CompanionTheme.danger }
        if remainingPercent < 20 { return CompanionTheme.warning }
        return CompanionTheme.accent
    }

    public func countdown(now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    public func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetAt else {
            if let pct = remainingPercent, pct >= 100 { return 0.0 }
            return nil
        }
        let token = cadence.isEmpty ? label : cadence
        let words = "\(token) \(label)".lowercased()
        let durationSeconds: TimeInterval? = {
            if words.contains("7d") || words.contains("7-day") || words.contains("weekly") || words.contains("1w") || words.contains("org") || words.contains("quota") { return 7 * 86400 }
            if words.contains("5h") || words.contains("5-hour") || words.contains("five_hour") || words.contains("coding plan") || words.contains("coding_plan") || words.contains("interval") { return 5 * 3600 }
            if words.contains("4h") || words.contains("4-hour") || words.contains("four_hour") { return 4 * 3600 }
            if words.contains("1d") || words.contains("daily") || words.contains("24h") { return 86400 }
            if words.contains("billing") || words.contains("cycle") || words.contains("monthly") || words.contains("month") { return 30 * 86400 }
            return nil
        }()
        guard let duration = durationSeconds, duration > 0 else { return nil }
        let start = resetAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0 else { return 0.0 }
        return min(1.0, max(0.0, elapsed / duration))
    }

    public var caption: String { meterCaption }

    /// Companion meters use hyphenated cadence only; no secondary qualifier line.
    public var barQualifier: String { "" }

    /// Countdown or a placeholder when an extra allowance has no reset clock.
    public func meterCountdown(now: Date = Date()) -> String {
        if QuotaWindowVocabulary.isExtraAllowanceLabel(label) { return "extra" }
        let cd = countdown(now: now)
        return cd.isEmpty ? "—" : cd
    }

    public var isShortCadence: Bool {
        let text = (cadence.isEmpty ? label : cadence).lowercased()
        if text.contains("7d") || text.contains("1w") || text.contains("weekly") || text.contains("month") || text.contains("billing") || text.contains("cycle") || text.contains("30d") || text.contains("1m") || text.contains("org") || text.contains("quota") { return false }
        if text.contains("5h") || text.contains("5-hour") || text.contains("5 hour") || text.contains("five_hour")
            || text.contains("4h") || text.contains("4-hour") || text.contains("4 hour") || text.contains("four_hour")
            || text.contains("session") || text.contains("fast") || text.contains("coding plan") || text.contains("coding_plan") || text.contains("interval") { return true }
        if text.contains("plan") { return false }
        if let sec = ResetAlarmCadence.periodSeconds(token: cadence, label: label) {
            return sec < 86_400
        }
        if let reset = resetAt {
            return reset.timeIntervalSinceNow < 86_400
        }
        return true
    }

    public var cadencePeriodSeconds: TimeInterval {
        ResetAlarmCadence.periodSeconds(token: cadence, label: label)
            ?? (isShortCadence ? 5 * 3_600 : 7 * 86_400)
    }
}

/// An overarching platform section displayed in the CodeCaps iOS companion app.
/// Holds all active time periods / windows for that platform, plus any duplicate sources folded under it.
public struct CompanionQuotaItem: Identifiable, Codable, Equatable {
    public let id: String
    public let providerKey: String
    public let title: String
    public let subtitle: String?
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let isExhausted: Bool
    /// This provider's own reset-alarm pick, shown by its row's bell while
    /// All is off.  Whether the alarm is actually on also depends on All.
    public var isAlarmEnabled: Bool
    public let windows: [CompanionWindowItem]
    public let duplicateWindows: [CompanionWindowItem]
    /// Server-supplied icon hint (Phase 2 backend manifest).  Optional, so
    /// older snapshots still decode; populated only when the iOS companion
    /// received an envelope with `providerGroups[].iconHint`.
    public let iconHint: String?
    /// Server-supplied fallback window label for this provider.  Used by the
    /// widget when the provider has no windows yet.
    public let defaultWindowLabel: String?

    public var shortWindow: CompanionWindowItem? {
        if let short = windows.first(where: { $0.isShortCadence }) {
            return short
        }
        return windows.first
    }

    public var longWindow: CompanionWindowItem? {
        let nonShort = windows.filter { !$0.isShortCadence }
        if let match = nonShort.first(where: { $0.id != shortWindow?.id }) {
            return match
        }
        return windows.first(where: { $0.id != shortWindow?.id })
    }

    /// A platform card is only expandable if it reports more than two allowance
    /// windows, so single and dual window cards never repeat their face data.
    public var isExpandable: Bool {
        windows.count > 2
    }

    /// Both feeds must report within this window for a source-disagreement banner.
    public static let sourceDiscrepancyFreshnessWindow: TimeInterval = FleetSourceDisagreement.alertFreshnessWindow

    public struct CardWindow: Equatable, Sendable {
        public let window: CompanionWindowItem
        public let updatedLabel: String?

        public init(window: CompanionWindowItem, updatedLabel: String?) {
            self.window = window
            self.updatedLabel = updatedLabel
        }
    }

    /// One discrepancy where an additional/duplicate source diverges from its matching primary window by at least 10 points.
    public struct SourceDiscrepancy: Identifiable, Equatable, Sendable {
        public var id: String { "\(primaryWindow.id)-\(duplicateWindow.id)" }
        public let primaryWindow: CompanionWindowItem
        public let duplicateWindow: CompanionWindowItem
        public let delta: Double
        public let description: String

        public init(primaryWindow: CompanionWindowItem, duplicateWindow: CompanionWindowItem, delta: Double, description: String) {
            self.primaryWindow = primaryWindow
            self.duplicateWindow = duplicateWindow
            self.delta = delta
            self.description = description
        }
    }

    /// Source disagreements when All Sources is on, the card shows a multi-source
    /// chip, and two fresh feeds for the same allowance differ by at least 10 points.
    public func sourceDiscrepancies(scope: CompanionSourceScope) -> [SourceDiscrepancy] {
        guard scope == .allSources, sourceCount >= 2 else { return [] }
        var results: [SourceDiscrepancy] = []
        let now = Date()
        for dup in duplicateWindows {
            guard let primary = windows.first(where: { $0.normalizedWindowKey == dup.normalizedWindowKey }) else {
                continue
            }
            if Self.sourceLooksLikeHostname(primary.source) || Self.sourceLooksLikeHostname(primary.via)
                || Self.sourceLooksLikeHostname(dup.source) || Self.sourceLooksLikeHostname(dup.via) {
                continue
            }
            let primaryReading = FleetSourceReading(
                remainingPercent: primary.remainingPercent,
                reportedAt: primary.reportedAt
            )
            let duplicateReading = FleetSourceReading(
                remainingPercent: dup.remainingPercent,
                reportedAt: dup.reportedAt
            )
            guard FleetSourceDisagreement.shouldShowDisagreementAlert(
                primary: primaryReading,
                duplicate: duplicateReading,
                now: now
            ) else { continue }
            guard let pPct = primary.remainingPercent, let dPct = dup.remainingPercent else { continue }
            let delta = abs(pPct - dPct)
            guard delta >= 10.0 else { continue }
            let desc = "Sources differ · \(Int(pPct.rounded()))% and \(Int(dPct.rounded()))%"
            results.append(SourceDiscrepancy(
                primaryWindow: primary,
                duplicateWindow: dup,
                delta: delta,
                description: desc
            ))
        }
        return results
    }

    public func hasSourceDiscrepancy(scope: CompanionSourceScope) -> Bool {
        guard scope == .allSources, sourceCount >= 2 else { return false }
        return !sourceDiscrepancies(scope: scope).isEmpty
    }

    /// Stable key for matching primary and mirror windows on the same allowance.
    static func allowanceKey(for window: CompanionWindowItem) -> String {
        window.normalizedWindowKey
    }

    private static func sourceLooksLikeHostname(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return raw.contains(".") && !raw.contains(" ")
    }

    /// Main-card windows: fresh Mac CodeCaps readings win; otherwise the newest feed with an Updated label.
    public func cardWindowRows(scope: CompanionSourceScope, now: Date = Date()) -> [CardWindow] {
        windows.map { primary in
            let key = Self.allowanceKey(for: primary)
            // This iPhone: only this device's primary windows. All Sources: fold
            // in mirror feeds so Mac/fleet readings can win when fresher.
            let mirrors: [CompanionWindowItem]
            if scope == .allSources {
                mirrors = duplicateWindows.filter { Self.allowanceKey(for: $0) == key }
            } else {
                mirrors = []
            }
            let pool = mirrors.isEmpty ? [primary] : [primary] + mirrors
            return Self.resolveCardWindow(pool: pool, now: now)
        }
    }

    public func cardWindows(scope: CompanionSourceScope, now: Date = Date()) -> [CompanionWindowItem] {
        cardWindowRows(scope: scope, now: now).map(\.window)
    }

    public func cardShortWindow(scope: CompanionSourceScope, now: Date = Date()) -> CardWindow? {
        let resolved = cardWindowRows(scope: scope, now: now)
        if providerKey == "muse-assist" {
            if let weekly = resolved.first(where: {
                QuotaWindowVocabulary.isMuseAssistWeekly(
                    providerKey: providerKey,
                    windowToken: nil,
                    label: $0.window.label,
                    resetAt: $0.window.resetAt
                )
            }) {
                return weekly
            }
        }
        let window = resolved.map(\.window).first(where: { $0.isShortCadence }) ?? resolved.first?.window
        return resolved.first(where: { $0.window.id == window?.id })
    }

    public func cardLongWindow(scope: CompanionSourceScope, now: Date = Date()) -> CardWindow? {
        let resolved = cardWindowRows(scope: scope, now: now)
        if providerKey == "muse-assist" {
            if let extra = resolved.first(where: {
                QuotaWindowVocabulary.isMuseAssistExtra(
                    providerKey: providerKey,
                    windowToken: nil,
                    label: $0.window.label,
                    resetAt: $0.window.resetAt
                )
            }) {
                return extra
            }
        }
        let short = cardShortWindow(scope: scope, now: now)?.window
        let nonShort = resolved.filter { !$0.window.isShortCadence }
        if let match = nonShort.first(where: { $0.window.id != short?.id }) {
            return match
        }
        return resolved.first(where: { $0.window.id != short?.id })
    }

    /// The card's headline percentage: the lowest honest reading on the card.
    ///
    /// A masked window is left out, because its reading is a number that must
    /// not be believed.  The five-hour window of a pool whose weekly cap is
    /// spent reports whatever it last saw, and the card put that on its
    /// headline while the label beside it said "n/a".
    public func cardRemainingPercent(scope: CompanionSourceScope, now: Date = Date()) -> Double? {
        cardWindows(scope: scope, now: now)
            .filter { !$0.isMasked }
            .compactMap(\.remainingPercent)
            .min()
    }

    public func cardDisplayPercent(scope: CompanionSourceScope, now: Date = Date()) -> String {
        guard let remainingPercent = cardRemainingPercent(scope: scope, now: now) else { return "—" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    public func cardStatusColor(scope: CompanionSourceScope, now: Date = Date()) -> Color {
        guard let remainingPercent = cardRemainingPercent(scope: scope, now: now) else { return .secondary }
        if remainingPercent <= 0 { return CompanionTheme.danger }
        if remainingPercent < 20 { return CompanionTheme.warning }
        return CompanionTheme.accent
    }

    public var sourceDetailWindows: [CompanionWindowItem] {
        windows + duplicateWindows
    }

    public func isStaleInSourceDetail(_ window: CompanionWindowItem, scope: CompanionSourceScope, now: Date = Date()) -> Bool {
        let key = Self.allowanceKey(for: window)
        let peers = sourceDetailWindows.filter { Self.allowanceKey(for: $0) == key }
        guard peers.count > 1 else { return false }
        let displayed = Self.resolveCardWindow(pool: peers, now: now).window
        return window.id != displayed.id
    }

    private static func resolveCardWindow(pool: [CompanionWindowItem], now: Date) -> CardWindow {
        let observations = pool.map {
            FleetQuotaObservation(
                remainingPercent: $0.remainingPercent,
                reportedAt: $0.reportedAt,
                isMacCodeCapsReading: $0.isMacCodeCapsReading
            )
        }
        if let pick = FleetMacReading.pickCardDisplay(from: observations, now: now) {
            return CardWindow(window: pool[pick.chosenIndex], updatedLabel: pick.updatedLabel)
        }
        return CardWindow(window: pool[0], updatedLabel: nil)
    }

    public var sourceCount: Int {
        Set(windows.compactMap(\.source) + duplicateWindows.compactMap(\.source)).count
    }

    public init(
        id: String,
        providerKey: String,
        title: String,
        subtitle: String?,
        remainingPercent: Double?,
        resetAt: Date?,
        isExhausted: Bool,
        isAlarmEnabled: Bool,
        windows: [CompanionWindowItem] = [],
        duplicateWindows: [CompanionWindowItem] = [],
        iconHint: String? = nil,
        defaultWindowLabel: String? = nil
    ) {
        self.id = id
        self.providerKey = providerKey
        self.title = title
        self.subtitle = subtitle
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.isExhausted = isExhausted
        self.isAlarmEnabled = isAlarmEnabled
        self.windows = windows
        self.duplicateWindows = duplicateWindows
        self.iconHint = iconHint
        self.defaultWindowLabel = defaultWindowLabel
    }

    public var displayPercent: String {
        guard let remainingPercent else { return "—" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    public var statusColor: Color {
        guard let remainingPercent else { return .secondary }
        if remainingPercent <= 0 { return CompanionTheme.danger }
        if remainingPercent < 20 { return CompanionTheme.warning }
        return CompanionTheme.accent
    }

    /// The window that binds this provider's cap: a spent allowance, and among
    /// the spent ones the one that resets last, because the plan stays capped
    /// until that window recovers.
    ///
    /// Mirrors the Mac's `QuotaPlatformSection.atCapWindow()`, through the
    /// shared `QuotaCapRule`, so the two surfaces cannot disagree:
    ///
    /// - A window with no reading reports no cap.  When there is a reading it
    ///   decides, so a provider's exhausted word cannot override a reading that
    ///   says there is room left.  The phone used to let it, and could announce
    ///   a cap directly above a meter that read 50%.
    /// - A supplementary video allowance and a scoped pool allowance are
    ///   skipped:  they sit beside the subscription rather than inside it.
    /// - A primary window beats a sub-model window, so a plan with a window of
    ///   its own is capped by that one.
    /// - A masked window is skipped, because a masked reading is a real number
    ///   that must not be believed and only the Antigravity pool knows that.
    ///
    /// The windows are the card's own, resolved for the scope in view, so the
    /// cap line can never contradict the meters and the headline beside it.
    ///
    /// Owner 2026-10-21: the phone said nothing when a provider was at its
    /// cap, so a capped Codex or Antigravity plan looked like any other.
    public func atCapWindow(scope: CompanionSourceScope = .allSources, now: Date = Date()) -> CompanionWindowItem? {
        let windows = cardWindows(scope: scope, now: now)
        let facts = windows.map {
            QuotaCapRule.WindowFacts(
                id: $0.id,
                remainingPercent: $0.remainingPercent,
                resetAt: $0.resetAt,
                isMasked: $0.isMasked,
                isSupplementaryVideoQuota: $0.isSupplementaryVideoQuota,
                isScopedPoolAllowance: $0.isScopedPoolAllowance,
                isSubModelLimit: $0.isSubModelLimit
            )
        }
        guard let bindingIndex = QuotaCapRule.bindingWindowIndex(in: facts) else { return nil }
        return windows[bindingIndex]
    }

    /// "7-day cap resets in 1d 13h" — the same wording the Mac's menu-bar
    /// window and PiP use, so one plan reads the same on both surfaces.
    public func atCapSummary(scope: CompanionSourceScope = .allSources, now: Date = Date()) -> String? {
        guard let window = atCapWindow(scope: scope, now: now) else { return nil }
        return QuotaWindowVocabulary.atCapSummary(cadence: window.atCapCadenceLabel,
                                                  resetAt: window.resetAt,
                                                  now: now)
    }

    public var elapsedFraction: Double? {
        windows.compactMap { $0.elapsedFraction() }.first
    }

    public var providerLogoName: String? {
        let key = providerKey.lowercased()
        let lowId = id.lowercased()
        if lowId.contains("gemini") { return "provider-gemini" }
        if lowId.contains("third-party") { return "provider-antigravity" }
        if key.contains("anthropic") || key.contains("claude") { return "provider-claude" }
        if key.contains("openai") || key.contains("codex") { return "provider-openai" }
        if key.contains("cursor") { return "provider-cursor" }
        if key.contains("grok-bot") { return "provider-grok-bot" }
        if key.contains("grok") || key.contains("xai") { return "provider-grok" }
        if key.contains("minimax") { return "provider-minimax" }
        if key.contains("copilot") || lowId.contains("copilot") { return "provider-copilot" }
        if key.contains("muse-assist") || key.contains("muse_assist") { return "provider-muse-assist" }
        if key.contains("muse-code") || key.contains("muse_code") { return "provider-muse-code" }
        if key.contains("muse") { return "provider-muse-assist" }
        if key.contains("antigravity") || key.contains("gemini") { return "provider-gemini" }
        return nil
    }

    public var fallbackSymbolName: String {
        "questionmark.square.dashed"
    }

    public func countdown(now: Date = Date()) -> String {
        guard let resetAt else { return "" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// Foreground notification delegate for iOS, ensuring alerts and test notifications
/// show banners and play sound even when the user is actively viewing the app.
public final class CompanionNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = CompanionNotificationDelegate()

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        #if os(iOS)
        Task { @MainActor in
            completionHandler(RemotePushRegistration.shared.presentationOptions(for: notification))
        }
        #else
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
        #endif
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        #if os(iOS)
        Task { @MainActor in
            RemotePushRegistration.shared.recordReceived(notification: response.notification)
            completionHandler()
        }
        #else
        completionHandler()
        #endif
    }
}

/// The core observable model driving the CodeCaps iOS companion app.
///
/// Designed to be lightweight and zero-cloud or endpoint-driven:
/// 1. Can pull directly from the Mac's QuotaPublisher sync endpoint.
/// 2. Can read quota snapshots synced via iCloud Drive / App Group container.
/// 3. Manages iOS local notifications and Apple Watch alerts when quotas reset,
///    by the same rules as the Mac app (`ResetAlarmTracker`, shared).
/// 4. Groups windows into overarching platforms with multiple expandable time periods.
/// 5. Folds duplicate sources for the same data under the overarching platform.
/// 6. Supports customizable platform ordering matching the macOS preference.
@MainActor
public final class CompanionQuotaModel: ObservableObject {
    #if os(macOS)
    public static let appGroupId = "CC8UTF7ATG.codecaps"
    #else
    public static let appGroupId = "group.com.simplewithus.codecaps"
    #endif

    public static let customMarksDirectory: URL = {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("CodeCaps/CustomMarks", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    public static func customMarkURL(for providerKey: String, isDarkMode: Bool = false) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fm = FileManager.default
        var candidateDirs: [URL] = [customMarksDirectory]
        if let appGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let appGroupMarks = appGroup.appendingPathComponent("CustomMarks", isDirectory: true)
            if !candidateDirs.contains(appGroupMarks) {
                candidateDirs.insert(appGroupMarks, at: 0)
            }
        }
        for dir in candidateDirs {
            if isDarkMode {
                for ext in ["png", "svg", "jpg", "jpeg"] {
                    let darkUrl = dir.appendingPathComponent("\(key)-dark.\(ext)")
                    if fm.fileExists(atPath: darkUrl.path) { return darkUrl }
                }
            }
            for ext in ["png", "svg", "jpg", "jpeg"] {
                let url = dir.appendingPathComponent("\(key).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    public static func customMarkMode(for providerKey: String) -> String {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let defaults = UserDefaults(suiteName: appGroupId) ?? UserDefaults.standard
        return defaults.string(forKey: "customMarkMode_\(key)") ?? "color"
    }

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupId) ?? UserDefaults.standard
    }

    @Published public var items: [CompanionQuotaItem] = []
    @Published public var sourceScope: CompanionSourceScope = .thisIPhone
    @Published public var isRefreshing: Bool = false
    @Published public var lastUpdated: Date?
    /// Last failure worth telling the owner about.
    @Published public var lastError: String?
    /// Result of the most recent test notification, mirroring the macOS sheet.
    @Published public var testNotificationOutcome: TestNotificationOutcome?
    /// Whether the system reports notifications as denied, so the sheet can
    /// offer a route into Settings instead of a button that does nothing.
    @Published public var notificationsDenied = false
    @Published public private(set) var notificationStatus = "Checking system notification settings."
    @Published public var inAppAlert: CompanionInAppAlert?
    private var inAppQueue: [CompanionInAppAlert] = []
    private var inAppQueueGeneration: UInt64 = 0
    @Published public private(set) var alertSourceDevices: [String: String] = [:]
    @Published public var foregroundRefreshSeconds: Int = {
        let saved = UserDefaults.standard.object(forKey: "companionForegroundRefreshSeconds") as? Int ?? 60
        return [0, 30, 60, 300].contains(saved) ? saved : 60
    }() {
        didSet { UserDefaults.standard.set(foregroundRefreshSeconds, forKey: "companionForegroundRefreshSeconds") }
    }
    /// True when at least one real reading has been parsed.
    @Published public var hasDataSource = false
    @Published public private(set) var tokenStorageError: String?
    private let tokenStore: CompanionReadTokenStore

    /// Customizable platform display order.  Persisted to UserDefaults and App Group.
    @Published public var platformOrder: [String] {
        didSet {
            UserDefaults.standard.set(platformOrder, forKey: "platformOrder")
            sharedDefaults.set(platformOrder, forKey: "platformOrder")
            self.items = sortPlatforms(self.items)
        }
    }

    @Published public var syncEndpoint: String {
        didSet {
            syncConfigurationRevision &+= 1
            UserDefaults.standard.set(syncEndpoint, forKey: "companionSyncEndpoint")
            sharedDefaults.set(syncEndpoint, forKey: "companionSyncEndpoint")
        }
    }
    @Published public var syncToken: String {
        didSet {
            let status = tokenStore.save(syncToken, shared: sharedDefaults, standard: .standard)
            guard status == errSecSuccess else {
                syncToken = oldValue
                tokenStorageError = "Could not save the sync token in Keychain (error \(status))."
                    + sentenceGap + "The previous token remains in use."
                return
            }
            tokenStorageError = nil
            syncConfigurationRevision &+= 1
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    /// Clears the Keychain item and both legacy preferences through the same
    /// persistence path as clearing the secure field.
    public func removeSyncToken() {
        syncToken = ""
    }
    private var syncConfigurationRevision = 0
    /// All: every provider's reset alarm is on, and rows show no bells.  Off:
    /// only the providers in `alarmProviderIds` alarm.  The same model as the
    /// Mac app's All bell.
    @Published public var alarmsAll: Bool {
        didSet {
            sharedDefaults.set(alarmsAll, forKey: AlarmKeys.all)
            synchronizeRemoteAlertChoices()
            if alarmsAll && !oldValue { Task { await requestNotificationPermission() } }
        }
    }

    /// The providers picked one by one.  Kept while All is on, so turning All
    /// off again restores the owner's own selection.
    @Published public private(set) var alarmProviderIds: Set<String> {
        didSet {
            sharedDefaults.set(alarmProviderIds.sorted(), forKey: AlarmKeys.providers)
            synchronizeRemoteAlertChoices()
        }
    }

    /// Keys for the alarm choices and the tracker's state.
    enum AlarmKeys {
        static let all = "companionResetAlarmAll"
        static let providers = "companionResetAlarmProviders"
        static let trackerState = "companionResetAlarmTrackerState"
        /// Read once, by the migration, and removed.
        static let legacyNotifyOnReset = "companionNotifyOnReset"
        static let legacyArmedIds = "armedResetAlarmSectionIds"
    }

    /// The sound the reset alarm plays.  Persisted into the App Group
    /// container so a sound chosen on the Mac reads back on the
    /// companion app and survives a fresh launch on the iPhone.
    @Published public var alarmSound: ResetAlarmSound {
        didSet {
            UserDefaults.standard.set(alarmSound.rawValue, forKey: "companionAlarmSound")
            sharedDefaults.set(alarmSound.rawValue, forKey: "alarmSound")
        }
    }

    /// The reset detector, shared with the Mac app.  Its state is saved after
    /// every evaluation, so a relaunch neither loses a reset that came due nor
    /// announces one twice.
    private var alarmTracker: ResetAlarmTracker
    @Published public var alertPreferences: UsageAlertPreferences {
        didSet {
            alertPreferences.save(to: sharedDefaults, key: "companionAlertPreferences")
            let presentationChanged = alertPreferences.sourceInstanceId != oldValue.sourceInstanceId
                || UsageAlertKind.allCases.contains { alertPreferences[$0].wantsInAppMessage != oldValue[$0].wantsInAppMessage }
            if presentationChanged { inAppQueueGeneration &+= 1 }
            if alertPreferences.sourceInstanceId != oldValue.sourceInstanceId {
                inAppQueue = []
                inAppAlert = nil
                deliveredQuotaEvents = [:]
                sharedDefaults.removeObject(forKey: "companionDeliveredQuotaEvents")
            }
            if presentationChanged {
                inAppQueue.removeAll { !canPresentInApp($0, generation: inAppQueueGeneration) }
                if let current = inAppAlert, !canPresentInApp(current, generation: inAppQueueGeneration) { inAppAlert = nil }
                if inAppAlert == nil { scheduleNextInAppAlert() }
            }
            for (id, alert) in retryAlerts where !alertPreferences[alert.kind].hasDelivery {
                announcedAlertIds.insert(id)
                retryAlerts.removeValue(forKey: id)
            }
            persistRetryAlerts()
            NotificationCenter.default.post(name: Notification.Name("CodeCapsAlertPreferencesChanged"), object: nil)
            if UsageAlertKind.allCases.contains(where: { alertPreferences[$0].enabled && alertPreferences[$0].notification }) {
                Task { await requestNotificationPermission() }
            }
        }
    }

    public func synchronizeRemoteAlertChoices() {
        var choices = alertPreferences
        let owners = Dictionary(grouping: items, by: \.providerKey).mapValues { $0.map(\.id) }
        choices.resetProviders = CompanionAlertSourcePolicy.remoteResetProviders(
            all: alarmsAll, selected: alarmProviderIds, ownerIDsByProvider: owners)
        if choices != alertPreferences { alertPreferences = choices }
    }

    public func setRemoteResetProvider(_ provider: String, enabled: Bool) {
        let owners = items.filter { $0.providerKey == provider }.map(\.id)
        if enabled { alarmProviderIds.formUnion(owners) }
        else { alarmProviderIds.subtract(owners); alarmProviderIds.remove(provider) }
        for index in items.indices { items[index].isAlarmEnabled = alarmProviderIds.contains(items[index].id) }
    }

    public func remoteResetProviderIsSelected(_ provider: String) -> Bool {
        alertPreferences.resetProviders?.providerIDs.contains(provider) ?? false
    }

    public func presentInAppAlert(id: String, kind: UsageAlertKind, title: String, body: String, sourceInstanceId: String? = nil) {
        let alert = CompanionInAppAlert(id: id, title: title, body: body, kind: kind, sourceInstanceId: sourceInstanceId)
        guard canPresentInApp(alert, generation: inAppQueueGeneration) else { return }
        var seen = sharedDefaults.stringArray(forKey: "companionInAppAlertIDs") ?? []
        guard !seen.contains(id) else { return }
        seen.append(id)
        sharedDefaults.set(Array(seen.suffix(200)), forKey: "companionInAppAlertIDs")
        guard inAppAlert?.id != id, !inAppQueue.contains(where: { $0.id == id }) else { return }
        if inAppAlert == nil { inAppAlert = alert }
        else { inAppQueue.append(alert) }
    }

    public func dismissInAppAlert() {
        inAppAlert = nil
        scheduleNextInAppAlert()
    }

    private func canPresentInApp(_ alert: CompanionInAppAlert, generation: UInt64) -> Bool {
        CompanionInAppAlertPolicy.canPresent(option: alertPreferences[alert.kind],
            selectedSource: alertPreferences.sourceInstanceId, reportedSource: alert.sourceInstanceId,
            scheduledGeneration: generation, currentGeneration: inAppQueueGeneration)
    }

    private func scheduleNextInAppAlert() {
        guard !inAppQueue.isEmpty else { return }
        let generation = inAppQueueGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == inAppQueueGeneration, inAppAlert == nil else { return }
            inAppQueue.removeAll { !canPresentInApp($0, generation: generation) }
            if !inAppQueue.isEmpty { inAppAlert = inAppQueue.removeFirst() }
        }
    }
    private var pendingAlertIds = Set<String>()
    private var pendingQuotaEvents = Set<String>()
    private var remoteQuotaEvents = Set<String>()
    private var exhaustionState: [String: Bool] = [:]
    private var alertTrackingStartedAt: Date = .distantFuture
    private var exhaustionObservedAt: [String: Date] = [:]
    private var deliveredQuotaEvents: [String: Date] = [:]
    private struct RetryAlert: Codable {
        let kind: UsageAlertKind
        let title: String
        let body: String
        let eventKey: String?
        let createdAt: Date
        let sourceInstanceId: String?
    }
    private var retryAlerts: [String: RetryAlert] = [:]

    public init() {
        let defaults = UserDefaults(suiteName: Self.appGroupId) ?? UserDefaults.standard
        let store = CompanionReadTokenStore(accessGroup: Self.appGroupId)
        let tokenState = store.loadAndMigrate(shared: defaults, standard: .standard)
        self.tokenStore = store
        self.syncEndpoint = defaults.string(forKey: "companionSyncEndpoint")
            ?? UserDefaults.standard.string(forKey: "companionSyncEndpoint") ?? ""
        self.syncToken = tokenState.token ?? ""

        // One-time migration of the two old mechanisms: a global "notify on
        // quota reset" switch, and one-shot bells armed per row.  The switch
        // meant "every provider", which is All; the bells meant "this row",
        // which is a per-provider pick.  Fresh installs require explicit opt-in.
        let legacyGlobal = defaults.object(forKey: AlarmKeys.legacyNotifyOnReset) as? Bool
            ?? UserDefaults.standard.object(forKey: AlarmKeys.legacyNotifyOnReset) as? Bool
        let hadResetPreferences = defaults.object(forKey: AlarmKeys.all) != nil
            || defaults.object(forKey: AlarmKeys.providers) != nil || legacyGlobal != nil
            || defaults.object(forKey: AlarmKeys.legacyArmedIds) != nil
        let all = CompanionResetAlertPolicy.allProviders(
            saved: defaults.object(forKey: AlarmKeys.all) as? Bool, legacy: legacyGlobal)
        let providers = Set(defaults.stringArray(forKey: AlarmKeys.providers)
                            ?? defaults.stringArray(forKey: AlarmKeys.legacyArmedIds) ?? [])
        defaults.set(all, forKey: AlarmKeys.all)
        defaults.set(providers.sorted(), forKey: AlarmKeys.providers)
        defaults.removeObject(forKey: AlarmKeys.legacyNotifyOnReset)
        defaults.removeObject(forKey: AlarmKeys.legacyArmedIds)
        UserDefaults.standard.removeObject(forKey: AlarmKeys.legacyNotifyOnReset)
        self.alarmsAll = all
        self.alarmProviderIds = providers
        self.alarmTracker = ResetAlarmTracker(
            state: ResetAlarmTrackerState.decoded(from: defaults.data(forKey: AlarmKeys.trackerState)))

        let sharedRaw = defaults.string(forKey: "alarmSound")
            ?? UserDefaults.standard.string(forKey: "companionAlarmSound")
        let migratedSound = sharedRaw.flatMap(ResetAlarmSound.init(rawValue:)) ?? .systemDefault
        self.alarmSound = migratedSound

        self.alertPreferences = UsageAlertPreferences.load(
            from: defaults, key: "companionAlertPreferences", resetEnabled: hadResetPreferences && (all || !providers.isEmpty),
            resetSound: migratedSound)
        self.platformOrder = defaults.stringArray(forKey: "platformOrder")
            ?? UserDefaults.standard.stringArray(forKey: "platformOrder") ?? []
        self.alertPreferences.save(to: defaults, key: "companionAlertPreferences")
        synchronizeRemoteAlertChoices()
        let trackingStart = defaults.object(forKey: "companionAlertTrackingStartedAt") as? Date ?? Date()
        self.alertTrackingStartedAt = trackingStart
        defaults.set(trackingStart, forKey: "companionAlertTrackingStartedAt")
        self.exhaustionState = defaults.dictionary(forKey: "companionExhaustionState") as? [String: Bool] ?? [:]
        self.exhaustionObservedAt = defaults.dictionary(forKey: "companionExhaustionObservedAt") as? [String: Date] ?? [:]
        self.deliveredQuotaEvents = defaults.dictionary(forKey: "companionDeliveredQuotaEvents") as? [String: Date] ?? [:]
        if let data = defaults.data(forKey: "companionRetryAlerts") {
            self.retryAlerts = (try? JSONDecoder().decode([String: RetryAlert].self, from: data)) ?? [:]
        }

        // Register the foreground notification delegate so test notifications
        // and reset alerts display banners and play sounds immediately.
        UNUserNotificationCenter.current().delegate = CompanionNotificationDelegate.shared

        Task { await refreshNotificationAuthorization() }
        loadLocalFallback()
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-previewAlertOptions") {
            var preview = alertPreferences
            for kind in UsageAlertKind.allCases {
                preview[kind] = UsageAlertOption(enabled: true, notification: false, popup: true, sound: .glass)
            }
            alertPreferences = preview
        }
        #endif
        switch tokenState {
        case .legacy(_, let status), .unavailable(let status):
            tokenStorageError = "Keychain could not secure the saved token (error \(status))."
                + sentenceGap + "It remains in preferences until you save it again."
        case .token, .missing:
            break
        }
    }

    /// Asks for notification permission and reports whether it was granted.
    @discardableResult
    public func requestNotificationPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            notificationsDenied = !granted
            await refreshNotificationAuthorization()
            return granted
        } catch {
            notificationsDenied = true
            return false
        }
    }

    /// Reads the real authorization state so the sheet can act on it.
    public func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = (settings.authorizationStatus == .denied)
        let authorization: String
        switch settings.authorizationStatus {
        case .notDetermined: authorization = "Permission has not been requested."
        case .denied: authorization = "System notifications are denied."
        case .authorized: authorization = "System notifications are allowed."
        case .provisional: authorization = "System notifications are delivered quietly."
        #if os(iOS)
        case .ephemeral: authorization = "Temporary notification permission is active."
        #endif
        @unknown default: authorization = "System notification permission is unknown."
        }
        notificationStatus = authorization + sentenceGap
            + "Banners: \(settings.alertSetting == .enabled ? "allowed" : "off"); sounds: \(settings.soundSetting == .enabled ? "allowed" : "off")."
    }

    /// Sends a test notification and reports what happened, matching the macOS button.
    public func sendTestNotification() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard await requestNotificationPermission() else {
                testNotificationOutcome = .denied
                return
            }
        } else if settings.authorizationStatus == .denied {
            notificationsDenied = true
            testNotificationOutcome = .denied
            return
        }

        notificationsDenied = false
        // Re-affirm foreground notification delegate
        UNUserNotificationCenter.current().delegate = CompanionNotificationDelegate.shared

        let content = UNMutableNotificationContent()
        content.title = "CodeCaps Reset Alert Test"
        content.body = alarmSound == .silent
            ? "Notification banners are working with sound set to Silent."
            : "Notification banners and the selected sound are working."
        content.sound = AlarmSoundPlayer.notificationSound(for: alarmSound)

        // Trigger with a brief delay (0.2s) ensures clean system dispatch
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        let request = UNNotificationRequest(
            identifier: "codecaps.companion.test.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            testNotificationOutcome = .sent
        } catch {
            testNotificationOutcome = .failed(error.localizedDescription)
        }
    }

    /// Whether `itemId`'s reset alarm is on: every provider under All,
    /// otherwise only the ones picked.
    public func isAlarmOn(for itemId: String) -> Bool {
        alarmsAll || alarmProviderIds.contains(itemId)
    }

    /// Turns one provider's alarm on or off; what a row's bell does while All is off.
    public func toggleProviderAlarm(for itemId: String) {
        let enabled = !alarmProviderIds.contains(itemId)
        if enabled {
            alarmProviderIds.insert(itemId)
            Task { await requestNotificationPermission() }
        } else {
            alarmProviderIds.remove(itemId)
        }
        if let index = items.firstIndex(where: { $0.id == itemId }) {
            items[index].isAlarmEnabled = enabled
        }
    }

    // MARK: - Platform Reordering

    public func movePlatform(from source: IndexSet, to destination: Int) {
        var current = items.map(\.id)
        current.move(fromOffsets: source, toOffset: destination)
        platformOrder = current
    }

    public func movePlatformUp(id: String) {
        var current = items.map(\.id)
        guard let idx = current.firstIndex(of: id), idx > 0 else { return }
        current.swapAt(idx, idx - 1)
        platformOrder = current
    }

    public func movePlatformDown(id: String) {
        var current = items.map(\.id)
        guard let idx = current.firstIndex(of: id), idx < current.count - 1 else { return }
        current.swapAt(idx, idx + 1)
        platformOrder = current
    }

    public func resetPlatformOrder() {
        platformOrder = []
    }

    private func sortPlatforms(_ list: [CompanionQuotaItem]) -> [CompanionQuotaItem] {
        guard !platformOrder.isEmpty else { return list }
        var orderMap: [String: Int] = [:]
        for (idx, key) in platformOrder.enumerated() {
            orderMap[key] = idx
        }
        return list.sorted { a, b in
            let idxA = orderMap[a.id] ?? orderMap[a.providerKey] ?? 999
            let idxB = orderMap[b.id] ?? orderMap[b.providerKey] ?? 999
            if idxA != idxB { return idxA < idxB }
            return a.title < b.title
        }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var failure: String?
        let requestedRevision = syncConfigurationRevision
        let requestedEndpoint = syncEndpoint
        let requestedToken = syncToken

        // Attempt endpoint fetch if configured
        if let url = URL(string: requestedEndpoint), !requestedEndpoint.isEmpty {
            do {
                var req = URLRequest(url: url)
                if !requestedToken.isEmpty {
                    req.setValue("Bearer \(requestedToken)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: req)
                guard requestedRevision == syncConfigurationRevision,
                      requestedEndpoint == syncEndpoint,
                      requestedToken == syncToken else { return }
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    if parseSnapshot(data: data) {
                        let widgetSnapshotSaved = saveLocalSnapshot(data: data)
                        lastError = widgetSnapshotSaved
                            ? nil
                            : "Quota readings loaded, but widget sharing is unavailable." + sentenceGap
                                + "Install the latest CodeCaps build and reopen the app."
                        lastUpdated = hasDataSource ? Date() : nil
                        return
                    }
                    failure = "The sync endpoint returned an invalid quota snapshot." + sentenceGap
                        + "Check the endpoint response and try again."
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode
                    failure = "The sync endpoint answered \(status.map(String.init) ?? "unexpectedly")." + sentenceGap
                        + "Check the endpoint and token in CodeCaps Settings."
                }
            } catch {
                guard requestedRevision == syncConfigurationRevision,
                      requestedEndpoint == syncEndpoint,
                      requestedToken == syncToken else { return }
                failure = "Could not reach the sync endpoint." + sentenceGap
                    + error.localizedDescription
            }
        }

        loadLocalFallback()

        if let failure {
            lastError = failure
        } else if hasDataSource {
            lastError = nil
        } else {
            lastError = "No quota readings yet." + sentenceGap
                + "Add a sync endpoint, or open CodeCaps on your Mac."
        }
        if lastUpdated == nil && hasDataSource {
            lastUpdated = Date()
        }
    }

    private struct WireEnvelope: Decodable {
        let windows: [WireRawWindow]?
        let customMarks: [String: WireCustomMark]?
        let providerGroups: [WireProviderGroup]?
        /// Alerts the Mac has already decided to raise.
        ///
        /// Owner request, 2026-10-08: "iOS should have info about heavy
        /// anomalies in usage or runaway usage like the mac."  The decision is
        /// made on the Mac because that is where the burn-rate history lives —
        /// a per-machine file of measured hourly intervals the phone has no way
        /// to reproduce.  Recomputing here would mean the two surfaces
        /// disagreeing about whether something was anomalous, which is worse
        /// than one surface staying quiet.
        ///
        /// Optional, so an older Mac's file still decodes and the companion
        /// simply has nothing extra to raise.
        let alerts: [WireAlert]?
    }

    /// One alert the Mac has already raised a verdict on.
    private struct WireAlert: Decodable, Equatable {
        let id: String
        let kind: String
        let providerKey: String
        let providerTitle: String
        let windowLabel: String
        let summary: String
        let occurredAt: String
        let sourceInstanceId: String?
    }

    private struct WireCustomMark: Decodable {
        let data: String
        let darkData: String?
        let mode: String
        let ext: String
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
        let source: String?
        let via: String?
        let resetAt: String?
        let occurredAt: String?
        let reportedAt: String?
        let quotaUnit: String?
        let absoluteRemaining: Double?
        let absoluteLimit: Double?
        let skip: Bool?
        let skipReason: String?
        let producerInstanceId: String?
        let machine: String?
    }

    /// Mirrors the backend manifest's provider group on the wire.  Optional
    /// fields decode as absent — older envelopes keep working.  `providerLabel`
    /// falls back to `provider` exactly like the canonical
    /// `QuotaProviderGroup` decoder, so a manifest group that omits the label
    /// can never make the whole `WireEnvelope` decode throw.  Encodable so
    /// the parsed manifest can be persisted for the widget byte-for-byte.
    private struct WireProviderGroup: Codable {
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

    private struct WireProviderTerms: Codable {
        let defaultWindowLabel: String?
    }

    // MARK: - Alerts from the Mac

    /// Alert ids already announced, so a payload rewritten on every refresh
    /// raises each one once rather than once per poll.
    private var announcedAlertIds: Set<String> {
        get {
            let stored = UserDefaults.standard.stringArray(forKey: "announcedAlertIds") ?? []
            return Set(stored)
        }
        set {
            UserDefaults.standard.set(Array(newValue).suffix(200), forKey: "announcedAlertIds")
        }
    }

    /// Raise each alert the Mac decided on that this phone has not announced.
    ///
    /// The Mac is the only surface that can make this call: the rules compare
    /// against its burn-rate history, a per-machine file of measured hourly
    /// intervals that does not exist on the phone.  So the phone announces what
    /// it is told, rather than deciding for itself — which also means the two
    /// surfaces cannot disagree about whether something counted as runaway.
    private func raisePendingAlerts(_ alerts: [WireAlert]) {
        remoteQuotaEvents = []
        for alert in alerts {
            guard let kind = UsageAlertKind(rawValue: alert.kind) else { continue }
            let sourceInstanceId = CompanionAlertSourcePolicy.sourceInstanceId(alertID: alert.id)
            guard CompanionAlertSourcePolicy.matches(selected: alertPreferences.sourceInstanceId, reported: sourceInstanceId) else {
                announcedAlertIds.insert(alert.id)
                continue
            }
            guard let occurred = CompanionDateFormatter.date(from: alert.occurredAt),
                  occurred >= alertTrackingStartedAt,
                  occurred <= Date(),
                  Date().timeIntervalSince(occurred) <= 15 * 60 else {
                announcedAlertIds.insert(alert.id)
                continue
            }
            let provider = CompanionAlertSourcePolicy.canonicalResetProvider(
                Self.canonicalManifestKey(provider: alert.providerKey, via: nil))
            let eventKey = Self.quotaEventKey(kind: kind, provider: provider, label: alert.windowLabel,
                                              sourceInstanceId: sourceInstanceId)
            remoteQuotaEvents.insert(eventKey)
            if (kind == .quotaReset || kind == .vendorReset),
               alertPreferences[kind].enabled && (alertPreferences[kind].notification || alertPreferences[kind].popup) {
                guard let selected = resetSelection(for: provider) else {
                    retryAlerts[alert.id] = RetryAlert(kind: kind, title: "\(kind.title): \(alert.providerTitle)",
                        body: alert.summary, eventKey: eventKey, createdAt: occurred, sourceInstanceId: sourceInstanceId)
                    persistRetryAlerts()
                    continue
                }
                guard selected else {
                    announcedAlertIds.insert(alert.id)
                    continue
                }
            }
            let quotaEvent = kind == .quotaReset || kind == .vendorReset || kind == .quotaExhaustion
            deliverAlert(id: alert.id, kind: kind, title: "\(kind.title): \(alert.providerTitle)", body: alert.summary,
                         eventKey: quotaEvent ? eventKey : nil, sourceInstanceId: sourceInstanceId)
        }
    }

    private func resetSelection(for provider: String) -> Bool? {
        CompanionResetAlertPolicy.selection(all: alarmsAll, selected: alarmProviderIds,
            provider: provider, currentOwnerIDs: items.filter { $0.providerKey == provider }.map(\.id))
    }

    private func retryPendingAlerts() {
        for (id, alert) in retryAlerts {
            guard Date().timeIntervalSince(alert.createdAt) <= 15 * 60,
                  CompanionAlertSourcePolicy.matches(selected: alertPreferences.sourceInstanceId, reported: alert.sourceInstanceId) else {
                announcedAlertIds.insert(id)
                retryAlerts.removeValue(forKey: id)
                persistRetryAlerts()
                continue
            }
            if (alert.kind == .quotaReset || alert.kind == .vendorReset),
               alertPreferences[alert.kind].enabled && (alertPreferences[alert.kind].notification || alertPreferences[alert.kind].popup) {
                guard let provider = alert.eventKey?.split(separator: "|").dropFirst().first,
                      let selected = resetSelection(for: String(provider)) else { continue }
                guard selected else {
                    announcedAlertIds.insert(id)
                    retryAlerts.removeValue(forKey: id)
                    persistRetryAlerts()
                    continue
                }
            }
            deliverAlert(id: id, kind: alert.kind, title: alert.title, body: alert.body, eventKey: alert.eventKey,
                         sourceInstanceId: alert.sourceInstanceId)
        }
    }

    static func quotaEventKey(kind: UsageAlertKind, provider: String, label: String, sourceInstanceId: String? = nil) -> String {
        let window = ResetAlarmCadence.periodSeconds(token: label, label: label).map { String($0) }
            ?? label.lowercased()
        return "\(kind.rawValue)|\(provider)|\(window)|\(sourceInstanceId?.lowercased() ?? "unknown")"
    }

    private func persistRetryAlerts() {
        if let data = try? JSONEncoder().encode(retryAlerts) {
            sharedDefaults.set(data, forKey: "companionRetryAlerts")
        }
    }

    /// Disabled events are consumed; accepted notifications are marked after enqueue succeeds.
    private func deliverAlert(id: String, kind: UsageAlertKind, title: String, body: String, eventKey: String? = nil,
                              sourceInstanceId: String? = nil) {
        guard !announcedAlertIds.contains(id), !pendingAlertIds.contains(id) else { return }
        if let eventKey, pendingQuotaEvents.contains(eventKey) { return }
        let option = alertPreferences[kind]
        if let saved = sharedDefaults.dictionary(forKey: "companionDeliveredQuotaEvents") as? [String: Date] {
            deliveredQuotaEvents.merge(saved) { max($0, $1) }
        }
        let recentlyDelivered = eventKey.flatMap { deliveredQuotaEvents[$0] }.map { Date().timeIntervalSince($0) < 90 } ?? false
        guard option.hasDelivery && !recentlyDelivered else {
            announcedAlertIds.insert(id)
            retryAlerts.removeValue(forKey: id)
            persistRetryAlerts()
            return
        }
        retryAlerts[id] = RetryAlert(kind: kind, title: title, body: body, eventKey: eventKey,
                                    createdAt: retryAlerts[id]?.createdAt ?? Date(),
                                    sourceInstanceId: sourceInstanceId ?? alertPreferences.sourceInstanceId)
        persistRetryAlerts()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = AlarmSoundPlayer.notificationSound(for: option.sound)
        pendingAlertIds.insert(id)
        if let eventKey { pendingQuotaEvents.insert(eventKey) }
        Task { @MainActor in
            defer {
                pendingAlertIds.remove(id)
                if let eventKey { pendingQuotaEvents.remove(eventKey) }
            }
            do {
                #if os(iOS)
                // Reconcile background APNs before polling announces the same wire ID.
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                for notification in delivered {
                    RemotePushRegistration.shared.recordReceived(notification: notification)
                }
                if announcedAlertIds.contains(id) {
                    retryAlerts.removeValue(forKey: id)
                    persistRetryAlerts()
                    return
                }
                #endif
                guard CompanionAlertSourcePolicy.matches(selected: alertPreferences.sourceInstanceId,
                                                         reported: retryAlerts[id]?.sourceInstanceId) else {
                    announcedAlertIds.insert(id)
                    retryAlerts.removeValue(forKey: id)
                    persistRetryAlerts()
                    return
                }
                if (kind == .quotaReset || kind == .vendorReset),
                   alertPreferences[kind].enabled && (alertPreferences[kind].notification || alertPreferences[kind].popup) {
                    guard let provider = eventKey?.split(separator: "|").dropFirst().first,
                          let selected = resetSelection(for: String(provider)) else { return }
                    guard selected else {
                        announcedAlertIds.insert(id)
                        retryAlerts.removeValue(forKey: id)
                        persistRetryAlerts()
                        return
                    }
                }
                guard alertPreferences[kind].enabled && (alertPreferences[kind].notification || alertPreferences[kind].popup) else {
                    announcedAlertIds.insert(id)
                    retryAlerts.removeValue(forKey: id)
                    persistRetryAlerts()
                    return
                }
                presentInAppAlert(id: id, kind: kind, title: title, body: body,
                                  sourceInstanceId: retryAlerts[id]?.sourceInstanceId)
                content.sound = AlarmSoundPlayer.notificationSound(for: alertPreferences[kind].sound)
                if alertPreferences[kind].notification {
                    try await UNUserNotificationCenter.current().add(
                        UNNotificationRequest(identifier: "codecaps.alert.\(id)", content: content, trigger: nil))
                }
                announcedAlertIds.insert(id)
                retryAlerts.removeValue(forKey: id)
                persistRetryAlerts()
                if let eventKey {
                    deliveredQuotaEvents[eventKey] = Date()
                    deliveredQuotaEvents = deliveredQuotaEvents.filter { Date().timeIntervalSince($0.value) < 90 }
                    sharedDefaults.set(deliveredQuotaEvents, forKey: "companionDeliveredQuotaEvents")
                }
            } catch {
                lastError = "An alert could not be delivered." + sentenceGap + error.localizedDescription
            }
        }
    }

    @discardableResult
    private func parseSnapshot(data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              let rawWindows = envelope.windows else { return false }
        alertSourceDevices = rawWindows.reduce(into: [:]) { devices, window in
            guard let raw = window.producerInstanceId, let id = UUID(uuidString: raw) else { return }
            devices[id.uuidString.lowercased()] = window.machine ?? "Mac (\(id.uuidString.prefix(8)))"
        }
        guard !rawWindows.isEmpty else {
            items = []
            synchronizeRemoteAlertChoices()
            retryPendingAlerts()
            raisePendingAlerts(envelope.alerts ?? [])
            hasDataSource = false
            lastUpdated = nil
            evaluateResets(newItems: [])
            return true
        }
        hasDataSource = true

        if let customMarks = envelope.customMarks, !customMarks.isEmpty {
            let dir = Self.customMarksDirectory
            let defaults = sharedDefaults
            for (key, mark) in customMarks {
                guard !key.isEmpty,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
                      ["png", "jpg", "jpeg", "svg", "webp"].contains(mark.ext.lowercased()) else { continue }
                if let raw = Data(base64Encoded: mark.data) {
                    try? raw.write(to: dir.appendingPathComponent("\(key).\(mark.ext)"), options: .atomic)
                }
                if let darkStr = mark.darkData, let rawDark = Data(base64Encoded: darkStr) {
                    try? rawDark.write(to: dir.appendingPathComponent("\(key)-dark.\(mark.ext)"), options: .atomic)
                }
                defaults.set(mark.mode, forKey: "customMarkMode_\(key)")
            }
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
                let id = [w.id, w.modelId, w.modelType, w.label].compactMap { $0 }.joined(separator: " ").lowercased()
                let isMiniMaxVideo = (pKey.contains("minimax") || w.provider.lowercased().contains("minimax"))
                    && (id.contains("video") || id.contains("hailuo"))
                if !isMiniMaxVideo {
                    nonAntigravityWindows.append(w)
                }
            }
        }

        var platformGroups: [String: (providerKey: String, title: String, iconHint: String?, windows: [WireRawWindow])] = [:]
        var platformKeyOrder: [String] = []

        for w in nonAntigravityWindows {
            let (platKey, platTitle, provKey) = Self.canonicalPlatformKey(for: w, manifest: envelope.providerGroups)
            if platformGroups[platKey] == nil {
                let manifestHint = Self.iconHint(for: platKey, in: envelope.providerGroups)
                platformGroups[platKey] = (providerKey: provKey, title: platTitle, iconHint: manifestHint, windows: [])
                platformKeyOrder.append(platKey)
            }
            platformGroups[platKey]?.windows.append(w)
        }

        var newItems: [CompanionQuotaItem] = []

        // Server-first ordering when the envelope carries a manifest: walk the
        // manifest entries first so the provider list reflects the admin's
        // current sort order, then append any future keys that arrived in the
        // windows payload but were not in the manifest.  An empty manifest
        // keeps the legacy "first-seen-wins" order (the offline-fallback path).
        let manifest = envelope.providerGroups ?? []
        let manifestKeys: [String] = manifest.isEmpty
            ? platformKeyOrder
            : manifest.compactMap { group in
                let key = Self.canonicalManifestKey(provider: group.provider, via: group.via)
                return key.isEmpty ? nil : key
            }

        for platKey in manifestKeys {
            guard let group = platformGroups[platKey] else { continue }
            let item = buildPlatformSection(
                id: platKey,
                providerKey: group.providerKey,
                title: group.title,
                iconHint: group.iconHint,
                rawWindows: group.windows
            )
            newItems.append(item)
        }
        // Future keys: in the windows payload but not in the manifest.
        for platKey in platformKeyOrder where !manifestKeys.contains(platKey) {
            guard let group = platformGroups[platKey] else { continue }
            let item = buildPlatformSection(
                id: platKey,
                providerKey: group.providerKey,
                title: group.title,
                iconHint: group.iconHint,
                rawWindows: group.windows
            )
            newItems.append(item)
        }

        // Consolidate Antigravity into two pools: Gemini and Third-Party
        if !antigravityWindows.isEmpty {
            let geminiWindows = antigravityWindows.filter {
                let s = ($0.id + " " + $0.label + " " + ($0.modelType ?? "") + " " + ($0.modelId ?? "")).lowercased()
                return s.contains("gemini")
            }
            let thirdPartyWindows = antigravityWindows.filter {
                let s = ($0.id + " " + $0.label + " " + ($0.modelType ?? "") + " " + ($0.modelId ?? "")).lowercased()
                return !s.contains("gemini")
            }

            if let geminiItem = consolidateAntigravityPool(
                poolKey: "gemini",
                title: "Antigravity · Gemini",
                defaultSubtitle: "Gemini Models",
                windows: geminiWindows
            ) {
                newItems.append(geminiItem)
            }

            if let thirdPartyItem = consolidateAntigravityPool(
                poolKey: "third-party",
                title: "Antigravity · Third-Party",
                defaultSubtitle: "Third-Party Models",
                windows: thirdPartyWindows
            ) {
                newItems.append(thirdPartyItem)
            }
        }

        // Persist the manifest into the App Group so the widget reads the same
        // labels/order/icon hints without redeclaring its own hardcoded table.
        // Encoded with JSONEncoder (never hand-rolled dictionaries: a nil
        // value in a [String: Any?] dictionary makes JSONSerialization throw,
        // which would silently skip persisting the manifest altogether).
        // Only touch the persisted key when the envelope actually supplied the
        // field: a local fallback file the Mac app wrote without a manifest
        // must not wipe a manifest a prior network sync persisted.
        if let groups = envelope.providerGroups {
            if groups.isEmpty {
                sharedDefaults.removeObject(forKey: "providerGroups")
            } else if let data = try? JSONEncoder().encode(groups) {
                sharedDefaults.set(data, forKey: "providerGroups")
            }
        }

        let sortedItems = sortPlatforms(newItems)
        self.items = sortedItems
        synchronizeRemoteAlertChoices()
        retryPendingAlerts()
        raisePendingAlerts(envelope.alerts ?? [])
        evaluateResets(newItems: sortedItems)
        evaluateExhaustion(newItems: sortedItems)
        return true
    }

    private static func reportedAt(from wire: WireRawWindow) -> Date? {
        if let reportedAt = wire.reportedAt,
           let parsed = CompanionDateFormatter.date(from: reportedAt) {
            return parsed
        }
        return CompanionDateFormatter.date(from: wire.occurredAt)
    }

    private func buildPlatformSection(
        id: String,
        providerKey: String,
        title: String,
        iconHint: String? = nil,
        rawWindows: [WireRawWindow]
    ) -> CompanionQuotaItem {
        var primaryWindows: [CompanionWindowItem] = []
        var duplicateWindows: [CompanionWindowItem] = []
        var seenCadenceKeys: Set<String> = []

        for w in rawWindows {
            let parsedReset = CompanionDateFormatter.date(from: w.resetAt)
            let cadence = Self.formatCadence(w.label, window: w.window, resetAt: parsedReset)
            let displayLabel = QuotaWindowVocabulary.windowLabel(
                windowToken: w.window,
                existingLabel: w.label,
                resetAt: parsedReset
            )
            let pct = w.remainingPercent
            // A reading decides, as it does on every surface:  the export never
            // clears `isExhausted`, so a stale word must not outvote a reading
            // that says there is room left.  The provider's word is the
            // fallback for a window that reports no figure at all.
            let exhausted = QuotaCapRule.isExhausted(remainingPercent: pct,
                                                      providerSaysExhausted: w.isExhausted ?? false)

            let modelQualifier = (w.modelId ?? "").lowercased()
            let isMiniMax = providerKey.lowercased().contains("minimax") || id.lowercased().contains("minimax")
            let effectiveQualifier = isMiniMax ? "" : modelQualifier
            let baseAllowanceKey = CompanionWindowItem.fallbackNormalizedWindowKey(
                cadence: cadence,
                label: displayLabel,
                resetAt: parsedReset
            )
            let cadenceKey = effectiveQualifier.isEmpty
                ? baseAllowanceKey
                : "\(effectiveQualifier):\(baseAllowanceKey)"
            let parsedReportedAt = Self.reportedAt(from: w)

            let isDuplicate = seenCadenceKeys.contains(cadenceKey)

            // The shared cap rule needs the window's own label, not the
            // display label:  the Mac reads the reader's own label, and that is
            // where the "argon" and "video" signals live.
            let capFlags = Self.capRuleFlags(
                provider: w.provider,
                providerKey: w.providerKey,
                via: w.via,
                id: w.id,
                modelId: w.modelId,
                modelType: w.modelType,
                label: w.label
            )

            let windowItem = CompanionWindowItem(
                id: w.id,
                label: displayLabel,
                cadence: cadence,
                remainingPercent: pct,
                resetAt: parsedReset,
                source: w.source,
                via: w.via,
                isDuplicateSource: isDuplicate,
                isExhausted: exhausted,
                isMasked: false,
                isSupplementaryVideoQuota: capFlags.isSupplementaryVideoQuota,
                isScopedPoolAllowance: capFlags.isScopedPoolAllowance,
                isSubModelLimit: capFlags.isSubModelLimit,
                absoluteRemaining: w.absoluteRemaining,
                absoluteLimit: w.absoluteLimit,
                quotaUnit: w.quotaUnit,
                reportedAt: parsedReportedAt,
                normalizedWindowKey: cadenceKey,
                producerInstanceId: w.producerInstanceId
            )

            if isDuplicate {
                duplicateWindows.append(windowItem)
            } else {
                seenCadenceKeys.insert(cadenceKey)
                primaryWindows.append(windowItem)
            }
        }

        // Standardize cadence order: shorter periods (e.g. 5-hour) precede longer periods (e.g. weekly).
        primaryWindows.sort { left, right in
            if providerKey == "muse-assist" {
                let leftWeekly = QuotaWindowVocabulary.isMuseAssistWeekly(
                    providerKey: providerKey, windowToken: nil, label: left.label, resetAt: left.resetAt)
                let rightWeekly = QuotaWindowVocabulary.isMuseAssistWeekly(
                    providerKey: providerKey, windowToken: nil, label: right.label, resetAt: right.resetAt)
                if leftWeekly != rightWeekly { return leftWeekly }
                let leftExtra = QuotaWindowVocabulary.isMuseAssistExtra(
                    providerKey: providerKey, windowToken: nil, label: left.label, resetAt: left.resetAt)
                let rightExtra = QuotaWindowVocabulary.isMuseAssistExtra(
                    providerKey: providerKey, windowToken: nil, label: right.label, resetAt: right.resetAt)
                if leftExtra != rightExtra { return !leftExtra }
            }
            if left.isShortCadence != right.isShortCadence {
                return left.isShortCadence && !right.isShortCadence
            }
            if left.cadencePeriodSeconds != right.cadencePeriodSeconds {
                return left.cadencePeriodSeconds < right.cadencePeriodSeconds
            }
            return left.id < right.id
        }

        // Controlling percentage is the minimum among primary non-masked windows
        let validPercents = primaryWindows.compactMap(\.remainingPercent)
        let controllingPct = validPercents.min()
        //  Each window above already decided through the shared rule, so the
        //  pool is exhausted when any of them is.  Evaluating the provider's
        //  word against `controllingPct` instead would compare a reading that
        //  belongs to a *different* window with the word of the window that
        //  has no reading at all:  a weekly the provider reports as gone,
        //  beside a healthy five-hour reading, would report the plan live.
        let isExhausted = primaryWindows.contains(where: \.isExhausted)

        // Nearest future reset time
        let now = Date()
        let futureResets = primaryWindows.compactMap(\.resetAt).filter { $0 > now }
        let nearestReset = futureResets.min() ?? primaryWindows.compactMap(\.resetAt).min()

        let sourceCount = Set(primaryWindows.compactMap(\.source) + duplicateWindows.compactMap(\.source)).count
        let sourceSuffix = sourceCount > 1 ? "  (\(sourceCount) sources)" : ""
        let subtitle = Self.subtitlePhrase(for: primaryWindows, fallback: title) + sourceSuffix
        let displayTitle = WidgetPlatformDisplay.title(
            canonicalKey: providerKey,
            manifestProviderLabel: title,
            wireProvider: nil
        )

        return CompanionQuotaItem(
            id: id,
            providerKey: providerKey,
            title: displayTitle,
            subtitle: subtitle,
            remainingPercent: controllingPct,
            resetAt: nearestReset,
            isExhausted: isExhausted,
            isAlarmEnabled: alarmProviderIds.contains(id),
            windows: primaryWindows,
            duplicateWindows: duplicateWindows,
            iconHint: iconHint
        )
    }

    private func consolidateAntigravityPool(
        poolKey: String,
        title: String,
        defaultSubtitle: String,
        windows: [WireRawWindow]
    ) -> CompanionQuotaItem? {
        guard !windows.isEmpty else { return nil }

        let itemId = "antigravity:\(poolKey)"
        let weeklyWin = windows.first {
            let s = ($0.id + " " + $0.label).lowercased()
            return s.contains("weekly") || s.contains("1w") || s.contains("7d")
        }
        let fiveHourWin = windows.first {
            let s = ($0.id + " " + $0.label).lowercased()
            return s.contains("5h") || s.contains("5-hour") || s.contains("interval")
        }

        let weeklyPct = weeklyWin?.remainingPercent
        // A reading decides, exactly as the Mac's `AntigravityQuotaGroups.weeklyIsSpent`
        // and the shared rule do:  the export never clears `isExhausted`, so
        // letting the wire's exhausted word override a healthy reading made
        // the phone call a live pool exhausted while the Mac kept it live, and
        // the two surfaces told the owner different things about one account.
        let weeklyExhausted = QuotaCapRule.isExhausted(remainingPercent: weeklyPct,
                                                        providerSaysExhausted: weeklyWin?.isExhausted ?? false)

        let controllingPct: Double?
        let isExhausted: Bool
        let sourceCount = Set(windows.compactMap(\.source)).count
        let sourceSuffix = sourceCount > 1 ? "  (\(sourceCount) sources)" : ""
        let subtitle: String

        if weeklyExhausted && weeklyWin != nil {
            controllingPct = weeklyPct ?? 0
            isExhausted = true
            subtitle = "\(QuotaWindowVocabulary.sevenDay) limit exhausted\(sourceSuffix)"
        } else {
            let validPercents = [fiveHourWin?.remainingPercent, weeklyWin?.remainingPercent].compactMap { $0 }
            if validPercents.isEmpty {
                let allPcts = windows.compactMap { $0.remainingPercent }
                controllingPct = allPcts.min()
                isExhausted = QuotaCapRule.isAtCap(remainingPercent: controllingPct)
                subtitle = "\(QuotaWindowVocabulary.fiveHour) & \(QuotaWindowVocabulary.sevenDay)\(sourceSuffix)"
            } else {
                controllingPct = validPercents.min()
                isExhausted = QuotaCapRule.isAtCap(remainingPercent: controllingPct)
                subtitle = "\(QuotaWindowVocabulary.fiveHour) & \(QuotaWindowVocabulary.sevenDay)\(sourceSuffix)"
            }
        }

        // Collapse the pool's observations into one row per period.
        //
        // Antigravity sells two shared pools, each with a short and a weekly
        // cap.  Per-model reports are *observations of those pools*, never
        // separate quotas, so listing one row per model contradicted the pool
        // the card is already named for and buried the two numbers that matter.
        // This mirrors `AntigravityQuotaGroups.normalize` on the macOS side:
        // prefer the latest observation of a period, break ties with the lower
        // value, and never average or add.
        let childWindows = Self.periodRows(
            poolKey: poolKey,
            windows: windows,
            weeklyExhausted: weeklyExhausted
        )

        let now = Date()
        let nearestReset = childWindows.compactMap(\.resetAt).filter { $0 > now }.min()
            ?? childWindows.compactMap(\.resetAt).min()

        return CompanionQuotaItem(
            id: itemId,
            providerKey: "google-antigravity",
            title: title,
            subtitle: subtitle,
            remainingPercent: controllingPct,
            resetAt: nearestReset,
            isExhausted: isExhausted,
            isAlarmEnabled: alarmProviderIds.contains(itemId),
            windows: childWindows,
            duplicateWindows: [],
            iconHint: poolKey == "third-party" ? "antigravity" : "gemini"
        )
    }

    /// The two periods an Antigravity pool is sold in, in display order.
    private static let antigravityPeriodOrder = ["5h", "weekly"]

    /// Whether a raw window reports the pool's short or its weekly cap, or
    /// `nil` when it reports neither.
    ///
    /// Mirrors `AntigravityQuotaGroups.cadence`: a weekly reading has to be
    /// explicitly identified rather than inferred from a reset distance, because
    /// a reset's distance is not a duration.
    ///
    /// `nil` is the common case, and it is a *discard*, not a third period.  A
    /// window like "Claude Opus 4.6 (Thinking)" or "GPT-OSS 120B (Medium)" names
    /// one model, not a period, so it is an observation of the pool's short cap
    /// and not a row of its own.  `AntigravityQuotaGroups.normalize` drops these
    /// from the export for exactly this reason, and the Mac shows two periods per
    /// pool because of it.
    private static func antigravityPeriod(of w: WireRawWindow) -> String? {
        let token = (w.window ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let label = w.label.lowercased()
        if ["weekly", "week", "1w", "7d", "168h", "10080m"].contains(token)
            || label.contains("weekly") || label.contains("week") {
            return "weekly"
        }
        if ["5h", "5hr", "5-hour", "5hours", "300m"].contains(token)
            || label.contains("5h") || label.contains("5-hour") || label.contains("five_hour") {
            return "5h"
        }
        return nil
    }

    /// The two rows an Antigravity pool shows: five-hour first, then weekly.
    private static func periodRows(
        poolKey: String,
        windows: [WireRawWindow],
        weeklyExhausted: Bool
    ) -> [CompanionWindowItem] {
        var buckets: [String: [WireRawWindow]] = [:]
        for w in windows {
            guard let period = antigravityPeriod(of: w) else { continue }
            buckets[period, default: []].append(w)
        }

        return antigravityPeriodOrder.compactMap { period in
            guard let candidates = buckets[period], !candidates.isEmpty else { return nil }

            // A pool period is one shared allowance, so one row reports it.  When
            // the payload carries the pool's own aggregate row -- the Mac exports
            // one per family per period, "Third-Party Models · Weekly" -- prefer
            // it, because that is the reading every surface agrees on.  Otherwise
            // take the latest observation, breaking a tie between two models of
            // the same pool with the lower value.  Never averaged, never added.
            let canonicalID = "antigravity:\(poolKey):\(period)"
            let driving = candidates.first { $0.id == canonicalID }
                ?? candidates.min { left, right in
                    let l = CompanionDateFormatter.date(from: left.resetAt) ?? .distantPast
                    let r = CompanionDateFormatter.date(from: right.resetAt) ?? .distantPast
                    if l != r { return l > r }
                    return (left.remainingPercent ?? 101) < (right.remainingPercent ?? 101)
                }
            guard let driving else { return nil }

            // A weekly the provider reports as gone without a figure still has to
            // publish a reading:  the shared cap rule only binds a window that
            // carries one, so without it the phone's cap line never appears.
            // The Mac does the same in `AntigravityQuotaGroups.pools`.
            //
            // The row's own provider word counts as well as the pool's:
            // `weeklyExhausted` is keyed off `weeklyWin`, chosen by scanning
            // ids and labels, while this row is built from `driving`, chosen
            // from the period buckets.  When the two pick different windows a
            // weekly the provider reports as gone would publish no reading and
            // never bind, or would publish a healthy reading under a headline
            // that says the weekly is exhausted.  A reading still outranks the
            // word, so this only decides the reading-less case.
            let providerSaysSpent = driving.isExhausted ?? false
            let pct = QuotaCapRule.publishedReading(
                remainingPercent: driving.remainingPercent,
                allowanceSpent: period == "weekly" && (weeklyExhausted || providerSaysSpent))
            let exhausted = QuotaCapRule.isExhausted(remainingPercent: pct,
                                                      providerSaysExhausted: providerSaysSpent)
            let parsedReset = CompanionDateFormatter.date(from: driving.resetAt)
            let cadenceToken = period == "5h" ? QuotaWindowVocabulary.fiveHour : QuotaWindowVocabulary.sevenDay
            let displayLabel = QuotaWindowVocabulary.windowLabel(
                windowToken: period == "5h" ? "5h" : "7d",
                existingLabel: cadenceToken,
                resetAt: parsedReset
            )
            let capFlags = Self.capRuleFlags(
                provider: driving.provider,
                providerKey: driving.providerKey,
                via: driving.via,
                id: driving.id,
                modelId: driving.modelId,
                modelType: driving.modelType,
                label: driving.label
            )

            return CompanionWindowItem(
                id: canonicalID,
                label: displayLabel,
                cadence: cadenceToken,
                remainingPercent: pct,
                resetAt: parsedReset,
                source: driving.source,
                via: driving.via,
                isDuplicateSource: false,
                isExhausted: exhausted,
                // A five-hour cap means nothing while the pool's weekly cap is
                // spent, so it is reported as not applicable rather than as a
                // number the owner cannot act on.
                isMasked: period == "5h" && weeklyExhausted,
                isSupplementaryVideoQuota: capFlags.isSupplementaryVideoQuota,
                isScopedPoolAllowance: capFlags.isScopedPoolAllowance,
                isSubModelLimit: capFlags.isSubModelLimit,
                absoluteRemaining: nil,
                absoluteLimit: nil,
                quotaUnit: nil,
                reportedAt: Self.reportedAt(from: driving),
                normalizedWindowKey: cadenceToken.lowercased(),
                producerInstanceId: driving.producerInstanceId
            )
        }
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
    /// local because the iOS bundle cannot import the Mac-side helpers; the
    /// aliases match.
    ///
    /// The provider key is preferred over the provider name, exactly as the
    /// Mac prefers it, so a window canonicalises to the same key on both
    /// surfaces.
    static func canonicalManifestKey(provider: String, providerKey: String? = nil, via: String?) -> String {
        let trimmedVia = via?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if trimmedVia == "antigravity" { return "google-antigravity" }
        let preferred = providerKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = (preferred.isEmpty ? provider : preferred).lowercased()
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

    /// The three window kinds the shared cap rule needs, for one wire window.
    ///
    /// The provider key is canonicalised the way the Mac canonicalises a
    /// window's own provider, so the phone asks `QuotaCapRule` the same
    /// question the Mac asks and the two surfaces skip the same windows.
    static func capRuleFlags(
        provider: String,
        providerKey: String?,
        via: String?,
        id: String,
        modelId: String?,
        modelType: String?,
        label: String
    ) -> (isSupplementaryVideoQuota: Bool, isScopedPoolAllowance: Bool, isSubModelLimit: Bool) {
        let canonical = canonicalManifestKey(provider: provider, providerKey: providerKey, via: via)
        return (
            isSupplementaryVideoQuota: QuotaCapRule.isSupplementaryVideoQuota(
                providerKey: canonical, modelId: modelId, modelType: modelType, label: label),
            isScopedPoolAllowance: QuotaCapRule.isScopedPoolAllowance(
                providerKey: canonical, id: id, modelId: modelId, modelType: modelType, label: label),
            isSubModelLimit: QuotaCapRule.isSubModelLimit(
                providerKey: canonical, id: id, modelId: modelId, modelType: modelType, label: label)
        )
    }

    /// The manifest's `iconHint` for the canonicalized key, if any.
    private static func iconHint(for canonicalKey: String, in manifest: [WireProviderGroup]?) -> String? {
        guard let manifest else { return nil }
        return manifest.first { canonicalManifestKey(provider: $0.provider, via: $0.via) == canonicalKey }?.iconHint
    }

    /// Card subtitle cadences use the same hyphenated vocabulary as meter captions.
    static func subtitlePhrase(for windows: [CompanionWindowItem], fallback: String) -> String {
        guard !windows.isEmpty else { return fallback }
        var seen = Set<String>()
        let uniqueTokens: [String] = windows.compactMap { window in
            let token = window.meterCaption
            guard !seen.contains(token) else { return nil }
            seen.insert(token)
            return token
        }
        guard !uniqueTokens.isEmpty else { return fallback }
        if uniqueTokens.count == 1 { return uniqueTokens[0] }
        if uniqueTokens.count == 2 {
            let first = windows.first { $0.meterCaption == uniqueTokens[0] }
            let second = windows.first { $0.meterCaption == uniqueTokens[1] }
            if let first, let second, first.isShortCadence != second.isShortCadence {
                let short = first.isShortCadence ? uniqueTokens[0] : uniqueTokens[1]
                let long = first.isShortCadence ? uniqueTokens[1] : uniqueTokens[0]
                return "\(short) & \(long)"
            }
            return "\(uniqueTokens[0]) & \(uniqueTokens[1])"
        }
        return uniqueTokens.joined(separator: " · ")
    }

    public static func formatCadence(_ label: String, window: String? = nil, resetAt: Date? = nil) -> String {
        let combined = "\(label) \(window ?? "")".lowercased()
        // MiniMax coding plan / interval is a 5-hour window even when the wire
        // token is opaque; classify before vocabulary so export matches Mac.
        let token: String?
        if combined.contains("coding plan") || combined.contains("interval") {
            token = "5h"
        } else {
            token = window
        }
        return QuotaWindowVocabulary.standardCadence(
            windowToken: token,
            label: label,
            resetAt: resetAt,
            periodStart: nil
        )
    }

    /// Feeds one snapshot's windows through the tracker, saves its state, and
    /// notifies once per provider for every alarm that is on.
    ///
    /// Every provider is tracked whether or not its alarm is on, so turning one
    /// on later starts from a real history rather than a blank one.
    private func evaluateResets(newItems: [CompanionQuotaItem]) {
        let now = Date()
        let before = alarmTracker.state
        let events = alarmTracker.process(Self.resetAlarmObservations(for: newItems, sourceInstanceId: alertPreferences.sourceInstanceId).filter {
            guard let observedAt = $0.observedAt else { return false }
            return observedAt <= now && now.timeIntervalSince(observedAt) <= FleetSourceDisagreement.alertFreshnessWindow
        }, now: now)
        if alarmTracker.state != before, let data = alarmTracker.state.encoded() {
            sharedDefaults.set(data, forKey: AlarmKeys.trackerState)
        }

        for event in events where isAlarmOn(for: event.providerId) {
            let kind: UsageAlertKind = event.isVendorReset ? .vendorReset : .quotaReset
            let provider = newItems.first { $0.id == event.providerId }?.providerKey ?? event.providerId
            let source = CompanionAlertSourcePolicy.instanceId(observationScope: event.scope)
            let eventKey = Self.quotaEventKey(kind: kind, provider: provider, label: event.windowLabel, sourceInstanceId: source)
            guard !remoteQuotaEvents.contains(eventKey) else { continue }
            let message = ResetAlarmMessage.content(for: [event])
            let key = "\(kind.rawValue)|\(event.scope)|\(event.providerId)|\(event.windowLabel)|\(event.endedPeriodResetAt?.timeIntervalSince1970 ?? now.timeIntervalSince1970)"
            deliverAlert(id: key, kind: kind, title: message.title, body: message.body, eventKey: eventKey, sourceInstanceId: source)
        }
    }

    private func evaluateExhaustion(newItems: [CompanionQuotaItem]) {
        for item in newItems {
            for window in item.windows where !window.isDuplicateSource && !window.isMasked {
                guard CompanionAlertSourcePolicy.matches(selected: alertPreferences.sourceInstanceId,
                                                         reported: window.producerInstanceId) else { continue }
                guard window.isFreshForSourceDiscrepancy(),
                      window.remainingPercent != nil || window.isExhausted else { continue }
                let source = CompanionAlertSourcePolicy.canonicalInstanceId(window.producerInstanceId)
                let key = CompanionAlertSourcePolicy.observationIdentity(provider: item.id, window: window.normalizedWindowKey,
                                                                          reportedInstanceId: source)
                guard let observedAt = window.reportedAt,
                      observedAt <= Date(),
                      observedAt > (exhaustionObservedAt[key] ?? .distantPast) else { continue }
                exhaustionObservedAt[key] = observedAt
                //  The shared cap rule decides, exactly as the Mac's own
                //  exhaustion path does:  the reading decides when there is
                //  one, and the provider's own exhausted word is the fallback
                //  for a window that reports no figure at all.
                let exhausted = QuotaCapRule.isExhausted(remainingPercent: window.remainingPercent,
                                                          providerSaysExhausted: window.isExhausted)
                let previous = exhaustionState[key]
                exhaustionState[key] = exhausted
                let eventKey = Self.quotaEventKey(kind: .quotaExhaustion, provider: item.providerKey, label: window.cadence,
                                                 sourceInstanceId: window.producerInstanceId)
                if !exhausted { deliveredQuotaEvents.removeValue(forKey: eventKey) }
                guard previous == false && exhausted,
                      !remoteQuotaEvents.contains(eventKey) else { continue }
                deliverAlert(id: "exhaustion|\(key)|\(window.reportedAt?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)",
                             kind: .quotaExhaustion, title: "Quota Exhausted: \(item.title)",
                             body: "\(window.label) has reached its limit.", eventKey: eventKey, sourceInstanceId: source)
            }
        }
        sharedDefaults.set(exhaustionState, forKey: "companionExhaustionState")
        sharedDefaults.set(exhaustionObservedAt, forKey: "companionExhaustionObservedAt")
    }

    /// One observation per primary window; a masked window reports no
    /// percentage, because its percentage must not be believed.
    static func resetAlarmObservations(for items: [CompanionQuotaItem], sourceInstanceId: String? = nil) -> [ResetAlarmObservation] {
        items.flatMap { item in
            item.windows.filter { !$0.isDuplicateSource && CompanionAlertSourcePolicy.matches(
                selected: sourceInstanceId, reported: $0.producerInstanceId) }.map { window in
                let period = ResetAlarmCadence.periodSeconds(
                    token: nil,
                    label: window.cadence,
                    monthlyHint: item.providerKey == "cursor" && window.cadence.lowercased().contains("plan"))
                return ResetAlarmObservation(
                    scope: CompanionAlertSourcePolicy.observationScope(reportedInstanceId: window.producerInstanceId),
                    providerId: item.id,
                    providerTitle: item.title,
                    windowId: window.normalizedWindowKey,
                    windowLabel: period.map(ResetAlarmCadence.caption(forPeriod:)) ?? window.cadence,
                    periodSeconds: period,
                    resetAt: window.resetAt,
                    remainingPercent: window.isMasked ? nil : window.remainingPercent,
                    observedAt: window.reportedAt)
            }
        }
    }

    static func notificationSound(for sound: ResetAlarmSound) -> UNNotificationSound? {
        AlarmSoundPlayer.notificationSound(for: sound)
    }

    private func loadLocalFallback() {
        // 1. First check shared App Group container
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            let sharedFile = container.appendingPathComponent("quota-windows.json")
            if let data = try? Data(contentsOf: sharedFile) {
                if parseSnapshot(data: data) {
                    if self.lastUpdated == nil,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: sharedFile.path),
                       let modDate = attrs[.modificationDate] as? Date {
                        self.lastUpdated = modDate
                    }
                    return
                }
            }
        }

        // 2. Check local sandbox Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localFile = appSupport.appendingPathComponent("CodeCaps/quota-windows.json")
            if FileManager.default.fileExists(atPath: localFile.path),
               let data = try? Data(contentsOf: localFile) {
                if parseSnapshot(data: data) {
                    if self.lastUpdated == nil,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: localFile.path),
                       let modDate = attrs[.modificationDate] as? Date {
                        self.lastUpdated = modDate
                    }
                    return
                }
            }
        }

        // 3. Check local sandbox Caches
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheFile = caches.appendingPathComponent("quota-windows.json")
            if FileManager.default.fileExists(atPath: cacheFile.path),
               let data = try? Data(contentsOf: cacheFile) {
                if parseSnapshot(data: data) {
                    if self.lastUpdated == nil,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
                       let modDate = attrs[.modificationDate] as? Date {
                        self.lastUpdated = modDate
                    }
                    return
                }
            }
        }

        #if targetEnvironment(simulator)
        // In the simulator, probe the host Mac's Application Support directory directly
        if let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir {
            let hostHome = String(cString: homeDir)
            let hostPath = "\(hostHome)/Library/Application Support/Usage Monitor/quota-windows.json"
            if FileManager.default.fileExists(atPath: hostPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: hostPath)) {
                if parseSnapshot(data: data) {
                    if self.lastUpdated == nil,
                       let attrs = try? FileManager.default.attributesOfItem(atPath: hostPath),
                       let modDate = attrs[.modificationDate] as? Date {
                        self.lastUpdated = modDate
                    }
                    return
                }
            }
        }
        #endif

        // On macOS or local simulator, check user Library
        let fallbackPath = ("~/Library/Application Support/Usage Monitor/quota-windows.json" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: fallbackPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)) {
            if parseSnapshot(data: data) {
                if self.lastUpdated == nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: fallbackPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    self.lastUpdated = modDate
                }
                return
            }
        }

        if items.isEmpty {
            items = []
        }
    }

    /// Persists the latest fetched snapshot to local storage so future launches
    /// immediately have quota data even before a network request completes.
    @discardableResult
    private func saveLocalSnapshot(data: Data) -> Bool {
        var sharedSnapshotSaved = false
        // Widgets cannot read the app's private fallback directories.  Report
        // a missing or unwritable group container instead of silently making
        // the readings look shared when the signed app lacks this capability.
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            let sharedFile = container.appendingPathComponent("quota-windows.json")
            do {
                try data.write(to: sharedFile, options: .atomic)
                sharedSnapshotSaved = true
            } catch {
                NSLog("CodeCaps could not write widget snapshot to app group %@: %@", Self.appGroupId, error.localizedDescription)
            }
        } else {
            NSLog("CodeCaps has no container for widget app group %@; widget readings will remain unavailable until signing is fixed.", Self.appGroupId)
        }

        // 2. Local sandbox Application Support directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("CodeCaps", isDirectory: true)
            let localFile = dir.appendingPathComponent("quota-windows.json")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: localFile, options: .atomic)
            } catch {
                NSLog("CodeCaps could not cache quota snapshot in Application Support: %@", error.localizedDescription)
            }
        }

        // 3. Local sandbox Caches directory
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheFile = caches.appendingPathComponent("quota-windows.json")
            do {
                try data.write(to: cacheFile, options: .atomic)
            } catch {
                NSLog("CodeCaps could not cache quota snapshot in Caches: %@", error.localizedDescription)
            }
        }
        #if canImport(WidgetKit)
        if sharedSnapshotSaved {
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
        return sharedSnapshotSaved
    }
}
