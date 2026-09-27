import Foundation
import SwiftUI
import UserNotifications

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
    public var isAlarmArmed: Bool
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
        isAlarmArmed: Bool,
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
        self.isAlarmArmed = isAlarmArmed
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
        let key = providerKey.lowercased()
        let lowId = id.lowercased()
        if lowId.contains("third-party") { return "sparkles" }
        if lowId.contains("gemini") { return "sparkles" }
        if key.contains("cursor") { return "chevron.left.forwardslash.chevron.right" }
        if key.contains("grok-bot") { return "sparkles.tv" }
        if key.contains("grok") { return "sparkle" }
        if key.contains("minimax") { return "waveform" }
        if key.contains("openai") || key.contains("codex") { return "apple.terminal" }
        if key.contains("anthropic") || key.contains("claude") { return "brain" }
        if key.contains("antigravity") || key.contains("gemini") { return "sparkles" }
        return "cpu"
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
/// 3. Manages iOS local notifications and Apple Watch alerts when quotas reset.
/// 4. Groups windows into overarching platforms with multiple expandable time periods.
/// 5. Folds duplicate sources for the same data under the overarching platform.
/// 6. Supports customizable platform ordering matching the macOS preference.
@MainActor
public final class CompanionQuotaModel: ObservableObject {
    public static let appGroupId = "group.com.simplewithus.codecaps"

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
    @Published public var notifyOnReset: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnReset, forKey: "companionNotifyOnReset")
            sharedDefaults.set(notifyOnReset, forKey: "companionNotifyOnReset")
        }
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

    private var previouslyExhaustedIds: Set<String> = []
    private var hasInitialized = false

    /// Ids armed on a previous launch, restored from the App Group.
    private var persistedArmedIds: Set<String> = []

    public init() {
        let defaults = UserDefaults(suiteName: Self.appGroupId) ?? UserDefaults.standard
        self.syncEndpoint = defaults.string(forKey: "companionSyncEndpoint")
            ?? UserDefaults.standard.string(forKey: "companionSyncEndpoint") ?? ""
        self.syncToken = defaults.string(forKey: "companionSyncToken")
            ?? UserDefaults.standard.string(forKey: "companionSyncToken") ?? ""
        self.notifyOnReset = defaults.object(forKey: "companionNotifyOnReset") as? Bool
            ?? UserDefaults.standard.object(forKey: "companionNotifyOnReset") as? Bool ?? true

        let sharedRaw = defaults.string(forKey: "alarmSound")
            ?? UserDefaults.standard.string(forKey: "companionAlarmSound")
        if let raw = sharedRaw, let picked = ResetAlarmSound(rawValue: raw) {
            self.alarmSound = picked
        } else {
            self.alarmSound = .systemDefault
        }

        self.persistedArmedIds = Set(defaults.stringArray(forKey: "armedResetAlarmSectionIds") ?? [])
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

    public func toggleAlarm(for itemId: String) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].isAlarmArmed.toggle()
        persistArmedIds()
        if items[index].isAlarmArmed {
            Task { await requestNotificationPermission() }
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

        if hasDataSource {
            lastError = nil
        } else if let failure {
            lastError = failure
        } else {
            lastError = "No quota readings yet." + sentenceGap
                + "Add a sync endpoint, or open CodeCaps on your Mac."
        }
        lastUpdated = Date()
    }

    private struct WireEnvelope: Decodable {
        let windows: [WireRawWindow]?
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
                defaultSubtitle: "Claude & GPT",
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
        let existingArmed = items.first(where: { $0.id == id })?.isAlarmArmed
            ?? persistedArmedIds.contains(id)

        var primaryWindows: [CompanionWindowItem] = []
        var duplicateWindows: [CompanionWindowItem] = []
        var seenCadenceKeys: Set<String> = []

        for w in rawWindows {
            let cadence = Self.formatCadence(w.label.isEmpty ? (w.window ?? "") : w.label)
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
            isAlarmArmed: existingArmed,
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
        let existingArmed = items.first(where: { $0.id == itemId })?.isAlarmArmed
            ?? persistedArmedIds.contains(itemId)

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

        // Build individual child window items for this pool
        var childWindows: [CompanionWindowItem] = []
        for w in windows {
            let labelText = windowText(w)
            let is5h = labelText.contains("5h") || labelText.contains("5-hour")
            let masked = is5h && weeklyExhausted
            let cadence = Self.formatCadence(w.label.isEmpty ? (w.window ?? "") : w.label)
            let parsedReset = CompanionDateFormatter.date(from: w.resetAt)
            let pct = w.remainingPercent
            let exhausted = (pct ?? 100) <= 0 || (w.isExhausted ?? false)

            childWindows.append(CompanionWindowItem(
                id: w.id,
                label: w.label.isEmpty ? cadence : w.label,
                cadence: cadence,
                remainingPercent: pct,
                resetAt: parsedReset,
                source: w.source,
                via: w.via,
                isDuplicateSource: false,
                isExhausted: exhausted,
                isMasked: masked,
                absoluteRemaining: w.absoluteRemaining,
                absoluteLimit: w.absoluteLimit,
                quotaUnit: w.quotaUnit
            ))
        }

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
            isAlarmArmed: existingArmed,
            windows: childWindows,
            duplicateWindows: []
        )
    }

    private func windowText(_ w: WireRawWindow) -> String {
        (w.id + " " + w.label + " " + (w.window ?? "")).lowercased()
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

    public static func formatCadence(_ label: String) -> String {
        let low = label.lowercased()
        if low.contains("5h") || low.contains("5-hour") || low.contains("five_hour") {
            return "5-hour window"
        }
        if low.contains("7d") || low.contains("seven_day") {
            return "7-day window"
        }
        if low.contains("1w") || low.contains("weekly") {
            return "Weekly window"
        }
        if low.contains("1d") || low.contains("daily") {
            return "Daily window"
        }
        if low.contains("billing") || low.contains("cycle") {
            return "Billing cycle"
        }
        return label
    }

    private func evaluateResets(newItems: [CompanionQuotaItem]) {
        guard hasInitialized else {
            previouslyExhaustedIds = Set(newItems.filter(\.isExhausted).map(\.id))
            hasInitialized = true
            return
        }

        var fired = Set<String>()
        for item in newItems {
            let wasExhausted = previouslyExhaustedIds.contains(item.id)
            let isArmed = item.isAlarmArmed

            if !item.isExhausted && (wasExhausted || isArmed) {
                if notifyOnReset || isArmed {
                    sendResetAlert(item: item)
                    fired.insert(item.id)
                }
            }
        }

        if !fired.isEmpty {
            for index in items.indices where fired.contains(items[index].id) {
                items[index].isAlarmArmed = false
            }
            persistArmedIds()
        }

        previouslyExhaustedIds = Set(newItems.filter(\.isExhausted).map(\.id))
    }

    private func sendResetAlert(item: CompanionQuotaItem) {
        let content = UNMutableNotificationContent()
        content.title = "Quota Reset: \(item.title)"
        content.body = "Quota has cleared (\(item.displayPercent) remaining)." + sentenceGap + "Ready for prompt turns."
        content.sound = AlarmSoundPlayer.notificationSound(for: alarmSound)

        let request = UNNotificationRequest(
            identifier: "codecaps.companion.reset.\(item.id).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        Task { @MainActor in
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                lastError = "A reset alert for \(item.title) could not be delivered." + sentenceGap
                    + error.localizedDescription
            }
        }
    }

    static func notificationSound(for sound: ResetAlarmSound) -> UNNotificationSound? {
        AlarmSoundPlayer.notificationSound(for: sound)
    }

    private func loadLocalFallback() {
        // First check shared App Group container
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupId) {
            let sharedFile = container.appendingPathComponent("quota-windows.json")
            if let data = try? Data(contentsOf: sharedFile) {
                parseSnapshot(data: data)
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
                if !items.isEmpty { return }
            }
        }
        #endif

        // On macOS or local simulator, check user Library
        let fallbackPath = ("~/Library/Application Support/Usage Monitor/quota-windows.json" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: fallbackPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)) {
            parseSnapshot(data: data)
            if !items.isEmpty { return }
        }

        if items.isEmpty {
            items = []
        }
    }

    // MARK: - Arm persistence

    private func persistArmedIds() {
        let armed = items.filter(\.isAlarmArmed).map(\.id)
        sharedDefaults.set(armed, forKey: "armedResetAlarmSectionIds")
    }
}
