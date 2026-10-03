import Foundation
import SwiftUI
import UserNotifications
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
    public let absoluteRemaining: Double?
    public let absoluteLimit: Double?
    public let quotaUnit: String?

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
        absoluteRemaining: Double? = nil,
        absoluteLimit: Double? = nil,
        quotaUnit: String? = nil
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
        self.absoluteRemaining = absoluteRemaining
        self.absoluteLimit = absoluteLimit
        self.quotaUnit = quotaUnit
    }

    public var displayPercent: String {
        if isMasked { return "n/a" }
        guard let remainingPercent else { return "—" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    public var statusColor: Color {
        if isMasked { return .secondary }
        guard let remainingPercent else { return .secondary }
        if remainingPercent <= 0 { return Color(red: 0.90, green: 0.25, blue: 0.25) }
        if remainingPercent < 20 { return Color(red: 0.95, green: 0.65, blue: 0.15) }
        return Color(red: 0.10, green: 0.70, blue: 0.45)
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
        guard let resetAt else { return nil }
        let token = cadence.isEmpty ? label : cadence
        let words = "\(token) \(label)".lowercased()
        let durationSeconds: TimeInterval? = {
            if words.contains("5h") || words.contains("5-hour") || words.contains("five_hour") { return 5 * 3600 }
            if words.contains("4h") || words.contains("4-hour") || words.contains("four_hour") { return 4 * 3600 }
            if words.contains("7d") || words.contains("7-day") || words.contains("weekly") || words.contains("1w") { return 7 * 86400 }
            if words.contains("1d") || words.contains("daily") { return 86400 }
            if words.contains("billing") || words.contains("cycle") || words.contains("monthly") { return 30 * 86400 }
            return nil
        }()
        guard let duration = durationSeconds, duration > 0 else { return nil }
        let start = resetAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= 0 else { return 0.0 }
        return min(1.0, max(0.0, elapsed / duration))
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
        duplicateWindows: [CompanionWindowItem] = []
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
    }

    public var displayPercent: String {
        guard let remainingPercent else { return "—" }
        return "\(Int(remainingPercent.rounded()))%"
    }

    public var statusColor: Color {
        guard let remainingPercent else { return .secondary }
        if remainingPercent <= 0 { return Color(red: 0.90, green: 0.25, blue: 0.25) }
        if remainingPercent < 20 { return Color(red: 0.95, green: 0.65, blue: 0.15) }
        return Color(red: 0.10, green: 0.70, blue: 0.45)
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
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
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
    public static let appGroupId = "group.com.simplewithus.codecaps"

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
    @Published public var isRefreshing: Bool = false
    @Published public var lastUpdated: Date?
    /// Last failure worth telling the owner about.
    @Published public var lastError: String?
    /// Result of the most recent test notification, mirroring the macOS sheet.
    @Published public var testNotificationOutcome: TestNotificationOutcome?
    /// Whether the system reports notifications as denied, so the sheet can
    /// offer a route into Settings instead of a button that does nothing.
    @Published public var notificationsDenied = false
    /// True when at least one real reading has been parsed.
    @Published public var hasDataSource = false

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
            UserDefaults.standard.set(syncEndpoint, forKey: "companionSyncEndpoint")
            sharedDefaults.set(syncEndpoint, forKey: "companionSyncEndpoint")
        }
    }
    @Published public var syncToken: String {
        didSet {
            UserDefaults.standard.set(syncToken, forKey: "companionSyncToken")
            sharedDefaults.set(syncToken, forKey: "companionSyncToken")
        }
    }
    /// All: every provider's reset alarm is on, and rows show no bells.  Off:
    /// only the providers in `alarmProviderIds` alarm.  The same model as the
    /// Mac app's All bell.
    @Published public var alarmsAll: Bool {
        didSet {
            sharedDefaults.set(alarmsAll, forKey: AlarmKeys.all)
            if alarmsAll && !oldValue { Task { await requestNotificationPermission() } }
        }
    }

    /// The providers picked one by one.  Kept while All is on, so turning All
    /// off again restores the owner's own selection.
    @Published public private(set) var alarmProviderIds: Set<String> {
        didSet { sharedDefaults.set(alarmProviderIds.sorted(), forKey: AlarmKeys.providers) }
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

    public init() {
        let defaults = UserDefaults(suiteName: Self.appGroupId) ?? UserDefaults.standard
        self.syncEndpoint = defaults.string(forKey: "companionSyncEndpoint")
            ?? UserDefaults.standard.string(forKey: "companionSyncEndpoint") ?? ""
        self.syncToken = defaults.string(forKey: "companionSyncToken")
            ?? UserDefaults.standard.string(forKey: "companionSyncToken") ?? ""

        // One-time migration of the two old mechanisms: a global "notify on
        // quota reset" switch, and one-shot bells armed per row.  The switch
        // meant "every provider", which is All; the bells meant "this row",
        // which is a per-provider pick.  A fresh install lands on All, like the
        // old switch's default.
        let legacyGlobal = defaults.object(forKey: AlarmKeys.legacyNotifyOnReset) as? Bool
            ?? UserDefaults.standard.object(forKey: AlarmKeys.legacyNotifyOnReset) as? Bool
        let all = defaults.object(forKey: AlarmKeys.all) as? Bool ?? legacyGlobal ?? true
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
        if let raw = sharedRaw, let picked = ResetAlarmSound(rawValue: raw) {
            self.alarmSound = picked
        } else {
            self.alarmSound = .systemDefault
        }

        self.platformOrder = defaults.stringArray(forKey: "platformOrder")
            ?? UserDefaults.standard.stringArray(forKey: "platformOrder") ?? []

        // Register the foreground notification delegate so test notifications
        // and reset alerts display banners and play sounds immediately.
        UNUserNotificationCenter.current().delegate = CompanionNotificationDelegate.shared

        Task { await refreshNotificationAuthorization() }
        loadLocalFallback()
    }

    /// Asks for notification permission and reports whether it was granted.
    @discardableResult
    public func requestNotificationPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            notificationsDenied = !granted
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
        content.body = "Reset alerts and alarms are working properly." + sentenceGap + "Sound and banner active."
        content.sound = AlarmSoundPlayer.notificationSound(for: alarmSound) ?? .default

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

        // Attempt endpoint fetch if configured
        if let url = URL(string: syncEndpoint), !syncEndpoint.isEmpty {
            do {
                var req = URLRequest(url: url)
                if !syncToken.isEmpty {
                    req.setValue("Bearer \(syncToken)", forHTTPHeaderField: "Authorization")
                }
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    parseSnapshot(data: data)
                    saveLocalSnapshot(data: data)
                    lastError = nil
                    lastUpdated = Date()
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode
                failure = "The sync endpoint answered \(status.map(String.init) ?? "unexpectedly")." + sentenceGap
                    + "Check the endpoint and token in Companion Settings."
            } catch {
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
        let quotaUnit: String?
        let absoluteRemaining: Double?
        let absoluteLimit: Double?
        let skip: Bool?
        let skipReason: String?
    }

    private func parseSnapshot(data: Data) {
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              let rawWindows = envelope.windows, !rawWindows.isEmpty else { return }
        hasDataSource = true

        if let customMarks = envelope.customMarks, !customMarks.isEmpty {
            let dir = Self.customMarksDirectory
            let defaults = sharedDefaults
            for (key, mark) in customMarks {
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
                nonAntigravityWindows.append(w)
            }
        }

        var platformGroups: [String: (providerKey: String, title: String, windows: [WireRawWindow])] = [:]
        var platformKeyOrder: [String] = []

        for w in nonAntigravityWindows {
            let (platKey, platTitle, provKey) = Self.canonicalPlatformKey(for: w)
            if platformGroups[platKey] == nil {
                platformGroups[platKey] = (providerKey: provKey, title: platTitle, windows: [])
                platformKeyOrder.append(platKey)
            }
            platformGroups[platKey]?.windows.append(w)
        }

        var newItems: [CompanionQuotaItem] = []

        // Process non-Antigravity platform sections
        for platKey in platformKeyOrder {
            guard let group = platformGroups[platKey] else { continue }
            let item = buildPlatformSection(
                id: platKey,
                providerKey: group.providerKey,
                title: group.title,
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

        let sortedItems = sortPlatforms(newItems)
        evaluateResets(newItems: sortedItems)
        self.items = sortedItems
    }

    private func buildPlatformSection(
        id: String,
        providerKey: String,
        title: String,
        rawWindows: [WireRawWindow]
    ) -> CompanionQuotaItem {
        var primaryWindows: [CompanionWindowItem] = []
        var duplicateWindows: [CompanionWindowItem] = []
        var seenCadenceKeys: Set<String> = []

        for w in rawWindows {
            let cadence = Self.formatCadence(w.label, window: w.window)
            let parsedReset = CompanionDateFormatter.date(from: w.resetAt)
            let pct = w.remainingPercent
            let exhausted = (pct ?? 100) <= 0 || (w.isExhausted ?? false)

            // Cadence key identifies the underlying allowance window / model tier.
            // E.g. "weekly", "5h", "general:5h", "video:1d".
            let modelQualifier = (w.modelId ?? "").lowercased()
            let normalizedCadence = cadence.lowercased()
            let cadenceKey = modelQualifier.isEmpty
                ? normalizedCadence
                : "\(modelQualifier):\(normalizedCadence)"

            let isDuplicate = seenCadenceKeys.contains(cadenceKey)

            let windowItem = CompanionWindowItem(
                id: w.id,
                label: w.label.isEmpty ? cadence : w.label,
                cadence: cadence,
                remainingPercent: pct,
                resetAt: parsedReset,
                source: w.source,
                via: w.via,
                isDuplicateSource: isDuplicate,
                isExhausted: exhausted,
                isMasked: false,
                absoluteRemaining: w.absoluteRemaining,
                absoluteLimit: w.absoluteLimit,
                quotaUnit: w.quotaUnit
            )

            if isDuplicate {
                duplicateWindows.append(windowItem)
            } else {
                seenCadenceKeys.insert(cadenceKey)
                primaryWindows.append(windowItem)
            }
        }

        // Controlling percentage is the minimum among primary non-masked windows
        let validPercents = primaryWindows.compactMap(\.remainingPercent)
        let controllingPct = validPercents.min()
        let isExhausted = (controllingPct ?? 100) <= 0 || primaryWindows.contains(where: \.isExhausted)

        // Nearest future reset time
        let now = Date()
        let futureResets = primaryWindows.compactMap(\.resetAt).filter { $0 > now }
        let nearestReset = futureResets.min() ?? primaryWindows.compactMap(\.resetAt).min()

        // Subtitle describing cadence windows
        let subtitle: String
        if primaryWindows.count == 1, let single = primaryWindows.first {
            if !duplicateWindows.isEmpty {
                subtitle = "\(single.cadence) · \(duplicateWindows.count + 1) sources"
            } else {
                subtitle = single.cadence
            }
        } else if primaryWindows.count > 1 {
            let cadences = primaryWindows.map(\.cadence)
            if cadences.count == 2 {
                subtitle = "\(cadences[0]) & \(cadences[1])"
            } else {
                subtitle = "\(primaryWindows.count) active windows"
            }
        } else {
            subtitle = title
        }

        return CompanionQuotaItem(
            id: id,
            providerKey: providerKey,
            title: title,
            subtitle: subtitle,
            remainingPercent: controllingPct,
            resetAt: nearestReset,
            isExhausted: isExhausted,
            isAlarmEnabled: alarmProviderIds.contains(id),
            windows: primaryWindows,
            duplicateWindows: duplicateWindows
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
        let weeklyExhausted = (weeklyPct ?? 100) <= 0 || (weeklyWin?.isExhausted ?? false)

        let controllingPct: Double?
        let isExhausted: Bool
        let subtitle: String

        if weeklyExhausted && weeklyWin != nil {
            controllingPct = weeklyPct ?? 0
            isExhausted = true
            subtitle = "\(defaultSubtitle) · Weekly limit exhausted"
        } else {
            let validPercents = [fiveHourWin?.remainingPercent, weeklyWin?.remainingPercent].compactMap { $0 }
            if validPercents.isEmpty {
                let allPcts = windows.compactMap { $0.remainingPercent }
                controllingPct = allPcts.min()
                isExhausted = (controllingPct ?? 100) <= 0
                subtitle = defaultSubtitle
            } else {
                controllingPct = validPercents.min()
                isExhausted = (controllingPct ?? 100) <= 0
                if let fPct = fiveHourWin?.remainingPercent, let wPct = weeklyWin?.remainingPercent {
                    if fPct < wPct {
                        subtitle = "\(defaultSubtitle) · 5h pool (Weekly \(Int(wPct.rounded()))%)"
                    } else if wPct < fPct {
                        subtitle = "\(defaultSubtitle) · Weekly pool (5h \(Int(fPct.rounded()))%)"
                    } else {
                        subtitle = "\(defaultSubtitle) · 5h & Weekly"
                    }
                } else {
                    subtitle = "\(defaultSubtitle) · 5-hour & Weekly"
                }
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
            duplicateWindows: []
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

            let pct = driving.remainingPercent
            let exhausted = (pct ?? 100) <= 0 || (driving.isExhausted ?? false)
            let cadenceLabel = period == "5h" ? "5-hour window" : "Weekly window"

            return CompanionWindowItem(
                id: canonicalID,
                label: cadenceLabel,
                cadence: cadenceLabel,
                remainingPercent: pct,
                resetAt: CompanionDateFormatter.date(from: driving.resetAt),
                source: driving.source,
                via: driving.via,
                isDuplicateSource: false,
                isExhausted: exhausted,
                // A five-hour cap means nothing while the pool's weekly cap is
                // spent, so it is reported as not applicable rather than as a
                // number the owner cannot act on.
                isMasked: period == "5h" && weeklyExhausted,
                absoluteRemaining: nil,
                absoluteLimit: nil,
                quotaUnit: nil
            )
        }
    }

    private static func canonicalPlatformKey(for raw: WireRawWindow) -> (key: String, title: String, providerKey: String) {
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
        return (fallbackKey.isEmpty ? "other" : fallbackKey, raw.provider, fallbackKey)
    }

    public static func formatCadence(_ label: String, window: String? = nil) -> String {
        let combined = "\(window ?? "") \(label)".lowercased()
        if combined.contains("5h") || combined.contains("5-hour") || combined.contains("five_hour") {
            return "5-hour window"
        }
        if combined.contains("4h") || combined.contains("4-hour") || combined.contains("four_hour") {
            return "4-hour window"
        }
        if combined.contains("7d") || combined.contains("seven_day") {
            return "7-day window"
        }
        if combined.contains("1w") || combined.contains("weekly") {
            return "Weekly window"
        }
        if combined.contains("1d") || combined.contains("daily") {
            return "Daily window"
        }
        if combined.contains("billing") || combined.contains("cycle") {
            return "Billing cycle"
        }
        if let window, !window.isEmpty {
            return window
        }
        return label
    }

    /// Feeds one snapshot's windows through the tracker, saves its state, and
    /// notifies once per provider for every alarm that is on.
    ///
    /// Every provider is tracked whether or not its alarm is on, so turning one
    /// on later starts from a real history rather than a blank one.
    private func evaluateResets(newItems: [CompanionQuotaItem]) {
        let now = Date()
        let before = alarmTracker.state
        let events = alarmTracker.process(Self.resetAlarmObservations(for: newItems), now: now)
        if alarmTracker.state != before, let data = alarmTracker.state.encoded() {
            sharedDefaults.set(data, forKey: AlarmKeys.trackerState)
        }

        var order: [String] = []
        var byProvider: [String: [ResetAlarmEvent]] = [:]
        for event in events where isAlarmOn(for: event.providerId) {
            if byProvider[event.providerId] == nil { order.append(event.providerId) }
            byProvider[event.providerId, default: []].append(event)
        }
        for providerId in order {
            guard let group = byProvider[providerId], !group.isEmpty else { continue }
            sendResetAlert(providerId: providerId, events: group)
        }
    }

    /// One observation per primary window; a masked window reports no
    /// percentage, because its percentage must not be believed.
    static func resetAlarmObservations(for items: [CompanionQuotaItem]) -> [ResetAlarmObservation] {
        items.flatMap { item in
            item.windows.map { window in
                let period = ResetAlarmCadence.periodSeconds(
                    token: nil,
                    label: window.cadence,
                    monthlyHint: item.providerKey == "cursor" && window.cadence.lowercased().contains("plan"))
                return ResetAlarmObservation(
                    scope: "companion",
                    providerId: item.id,
                    providerTitle: item.title,
                    windowId: window.id,
                    windowLabel: period.map(ResetAlarmCadence.caption(forPeriod:)) ?? window.cadence,
                    periodSeconds: period,
                    resetAt: window.resetAt,
                    remainingPercent: window.isMasked ? nil : window.remainingPercent,
                    observedAt: nil)
            }
        }
    }

    private func sendResetAlert(providerId: String, events: [ResetAlarmEvent]) {
        let message = ResetAlarmMessage.content(for: events)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = AlarmSoundPlayer.notificationSound(for: alarmSound)

        let request = UNNotificationRequest(
            identifier: "codecaps.companion.reset.\(providerId).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        Task { @MainActor in
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                lastError = "A reset alert for \(events.first?.providerTitle ?? "a provider") could not be delivered."
                    + sentenceGap + error.localizedDescription
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
                parseSnapshot(data: data)
                if self.lastUpdated == nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: sharedFile.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    self.lastUpdated = modDate
                }
                if !items.isEmpty { return }
            }
        }

        // 2. Check local sandbox Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let localFile = appSupport.appendingPathComponent("CodeCaps/quota-windows.json")
            if FileManager.default.fileExists(atPath: localFile.path),
               let data = try? Data(contentsOf: localFile) {
                parseSnapshot(data: data)
                if self.lastUpdated == nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: localFile.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    self.lastUpdated = modDate
                }
                if !items.isEmpty { return }
            }
        }

        // 3. Check local sandbox Caches
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheFile = caches.appendingPathComponent("quota-windows.json")
            if FileManager.default.fileExists(atPath: cacheFile.path),
               let data = try? Data(contentsOf: cacheFile) {
                parseSnapshot(data: data)
                if self.lastUpdated == nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
                   let modDate = attrs[.modificationDate] as? Date {
                    self.lastUpdated = modDate
                }
                if !items.isEmpty { return }
            }
        }

        #if targetEnvironment(simulator)
        // In the simulator, probe the host Mac's Application Support directory directly
        if let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir {
            let hostHome = String(cString: homeDir)
            let hostPath = "\(hostHome)/Library/Application Support/Usage Monitor/quota-windows.json"
            if FileManager.default.fileExists(atPath: hostPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: hostPath)) {
                parseSnapshot(data: data)
                if self.lastUpdated == nil,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: hostPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    self.lastUpdated = modDate
                }
                if !items.isEmpty { return }
            }
        }
        #endif

        // On macOS or local simulator, check user Library
        let fallbackPath = ("~/Library/Application Support/Usage Monitor/quota-windows.json" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: fallbackPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)) {
            parseSnapshot(data: data)
            if self.lastUpdated == nil,
               let attrs = try? FileManager.default.attributesOfItem(atPath: fallbackPath),
               let modDate = attrs[.modificationDate] as? Date {
                self.lastUpdated = modDate
            }
            if !items.isEmpty { return }
        }

        if items.isEmpty {
            items = []
        }
    }

    /// Persists the latest fetched snapshot to local storage so future launches
    /// immediately have quota data even before a network request completes.
    private func saveLocalSnapshot(data: Data) {
        // 1. Shared App Group container if available
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            let sharedFile = container.appendingPathComponent("quota-windows.json")
            try? data.write(to: sharedFile, options: .atomic)
        }

        // 2. Local sandbox Application Support directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("CodeCaps", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let localFile = dir.appendingPathComponent("quota-windows.json")
            try? data.write(to: localFile, options: .atomic)
        }

        // 3. Local sandbox Caches directory
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheFile = caches.appendingPathComponent("quota-windows.json")
            try? data.write(to: cacheFile, options: .atomic)
        }
    }
}
