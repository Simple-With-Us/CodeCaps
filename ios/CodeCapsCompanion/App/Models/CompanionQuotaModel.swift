import Foundation
import SwiftUI
import UserNotifications

/// An individual quota card model displayed in the CodeCaps iOS companion app.
public struct CompanionQuotaItem: Identifiable, Codable, Equatable {
    public let id: String
    public let providerKey: String
    public let title: String
    public let subtitle: String?
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let isExhausted: Bool
    public var isAlarmArmed: Bool

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
}

/// The core observable model driving the CodeCaps iOS companion app.
///
/// Designed to be lightweight and zero-cloud or endpoint-driven:
/// 1. Can pull directly from the Mac's QuotaPublisher sync endpoint.
/// 2. Can read quota snapshots synced via iCloud Drive container.
/// 3. Manages iOS local notifications and Apple Watch alerts when quotas reset.
@MainActor
public final class CompanionQuotaModel: ObservableObject {
    public static let appGroupId = "group.com.simplewithus.codecaps"

    private var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupId) ?? UserDefaults.standard
    }

    @Published public var items: [CompanionQuotaItem] = []
    @Published public var isRefreshing: Bool = false
    @Published public var lastUpdated: Date?
    /// Last failure worth telling the owner about.  The old code swallowed every
    /// fetch error in an empty `catch`, so a wrong endpoint or an expired token
    /// looked exactly like a healthy app.
    @Published public var lastError: String?
    /// Result of the most recent test notification, mirroring the macOS sheet.
    @Published public var testNotificationOutcome: TestNotificationOutcome?
    /// Whether the system reports notifications as denied, so the sheet can
    /// offer a route into Settings instead of a button that does nothing.
    @Published public var notificationsDenied = false
    /// True when at least one real reading has been parsed.  Drives the empty
    /// state, which replaces the old hardcoded fake rows.
    @Published public var hasDataSource = false
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
    /// Shared key is `alarmSound` — the same key the macOS
    /// `ResetAlarmManager` writes — so the picker order and the
    /// `silent` mute the alert on the iPhone exactly as it would on
    /// the host Mac.
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
        // Read the sound from the App Group first so a value picked on
        // Mac applies here too; fall back to a value previously stored
        // on this device, then the platform default.
        let sharedRaw = defaults.string(forKey: "alarmSound")
            ?? UserDefaults.standard.string(forKey: "companionAlarmSound")
        if let raw = sharedRaw, let picked = ResetAlarmSound(rawValue: raw) {
            self.alarmSound = picked
        } else {
            self.alarmSound = .systemDefault
        }

        self.persistedArmedIds = Set(defaults.stringArray(forKey: "armedResetAlarmSectionIds") ?? [])

        // Read the authorization state, but do not ask for it here.  Prompting
        // on first launch, before the owner has any reason to want alerts, is how
        // an app gets its permission prompt reflexively dismissed.  The request
        // now happens in context: arming a row's alarm, or pressing Send Test
        // Notification.  This matches the macOS app, which also asks on arming.
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

    /// Sends a test notification and reports what happened, matching the macOS
    /// button.  Requests authorization first and waits for the answer, because
    /// issuing the add before the prompt resolves is what made the original
    /// button look broken.
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
        let content = UNMutableNotificationContent()
        content.title = "CodeCaps Reset Alert Test"
        content.body = "Reset alerts and alarms are working properly." + sentenceGap + "Sound and banners active."
        content.sound = AlarmSoundPlayer.notificationSound(for: alarmSound)

        let request = UNNotificationRequest(
            identifier: "codecaps.companion.test.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
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

        // A fallback read is only a success if it produced something.  When the
        // endpoint failed and there is no local snapshot, say so -- the old code
        // reported nothing and the app just looked idle.
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
    }

    private func parseSnapshot(data: Data) {
        guard let envelope = try? JSONDecoder().decode(WireEnvelope.self, from: data),
              let rawWindows = envelope.windows, !rawWindows.isEmpty else { return }
        hasDataSource = true

        var newItems: [CompanionQuotaItem] = []
        var antigravityWindows: [WireRawWindow] = []

        for w in rawWindows {
            let pKey = (w.providerKey ?? w.provider).lowercased()
            let isAntigravity = pKey.contains("antigravity") || w.id.lowercased().contains("antigravity") || w.provider.lowercased().contains("antigravity")
            if isAntigravity {
                antigravityWindows.append(w)
            } else {
                let pct = w.remainingPercent
                let exhausted = (pct ?? 100) <= 0 || (w.isExhausted ?? false)
                let existingArmed = items.first(where: { $0.id == w.id })?.isAlarmArmed
                    ?? persistedArmedIds.contains(w.id)

                let (formattedTitle, formattedSubtitle) = Self.formatTitleAndSubtitle(
                    provider: w.provider,
                    providerKey: pKey,
                    label: w.label
                )

                newItems.append(CompanionQuotaItem(
                    id: w.id,
                    providerKey: pKey,
                    title: formattedTitle,
                    subtitle: formattedSubtitle,
                    remainingPercent: pct,
                    resetAt: nil,
                    isExhausted: exhausted,
                    isAlarmArmed: existingArmed
                ))
            }
        }

        // Consolidate Antigravity into exactly two pools: Gemini and Third-Party
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

        evaluateResets(newItems: newItems)
        self.items = newItems
    }

    private func consolidateAntigravityPool(
        poolKey: String,
        title: String,
        defaultSubtitle: String,
        windows: [WireRawWindow]
    ) -> CompanionQuotaItem? {
        guard !windows.isEmpty else { return nil }

        let itemId = "antigravity:\(poolKey)"
        let existingArmed = items.first(where: { $0.id == itemId })?.isAlarmArmed ?? false

        // Identify weekly vs 5-hour
        let weeklyWin = windows.first {
            let s = ($0.id + " " + $0.label).lowercased()
            return s.contains("weekly") || s.contains("1w") || s.contains("7d")
        }
        let fiveHourWin = windows.first {
            let s = ($0.id + " " + $0.label).lowercased()
            return s.contains("5h") || s.contains("5-hour") || s.contains("interval")
        }

        // Controlling logic:
        // If weekly is exhausted (0%), 5-hour is masked
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

        return CompanionQuotaItem(
            id: itemId,
            providerKey: "google-antigravity",
            title: title,
            subtitle: subtitle,
            remainingPercent: controllingPct,
            resetAt: nil,
            isExhausted: isExhausted,
            isAlarmArmed: existingArmed
        )
    }

    public static func formatTitleAndSubtitle(
        provider: String,
        providerKey: String,
        label: String
    ) -> (String, String) {
        let pKey = providerKey.lowercased()
        let prov = provider.lowercased()

        if pKey.contains("anthropic") || prov.contains("anthropic") || prov.contains("claude") {
            let sub = formatCadence(label)
            return ("Claude Code", sub)
        }
        if pKey.contains("openai") || prov.contains("openai") || prov.contains("codex") {
            let sub = formatCadence(label)
            return ("Codex", sub)
        }
        if pKey.contains("cursor") || prov.contains("cursor") {
            let sub = label.isEmpty ? "Included plan" : label
            return ("Cursor", sub)
        }
        if pKey.contains("grok-bot") || prov.contains("grok-bot") || prov.contains("grok bot") {
            let sub = formatCadence(label)
            return ("Grok Bot", sub)
        }
        if pKey.contains("grok") || prov.contains("grok") || pKey.contains("xai") || prov.contains("xai") {
            let sub = formatCadence(label)
            return ("Grok", sub)
        }
        if pKey.contains("minimax") || prov.contains("minimax") {
            let sub = formatCadence(label)
            return ("MiniMax", sub)
        }

        return (label, provider)
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

        // One-shot, matching the macOS manager: a fired alarm disarms itself so
        // the next clear does not alert again.  Without this an iOS alarm stayed
        // armed forever and re-fired on every refresh that saw the quota usable.
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
        // Pick the sound the user set in Settings.  `.silent` produces a nil
        // sound so the banner still appears but no chime plays, mirroring the
        // macOS picker.  Every other value resolves to bundled audio, because
        // the macOS system sound names this enum carries do not exist on iOS
        // and resolved to nothing at all -- a real alert was silently mute.
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

    /// Same translation rule as `ResetAlarmManager.notificationSound(for:)`
    /// on macOS, resolved against iOS's bundled audio.
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

        // On macOS or local simulator, check user Library
        let fallbackPath = ("~/Library/Application Support/Usage Monitor/quota-windows.json" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: fallbackPath),
           let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)) {
            parseSnapshot(data: data)
            if !items.isEmpty { return }
        }

        if items.isEmpty {
            // No fake rows.  The old fallback invented eight quotas at 100%
            // that were never measured, so a completely unconfigured app looked
            // healthy.  An honest empty state is what the macOS Glance shows.
            items = []
        }
    }

    // MARK: - Arm persistence

    /// Ids the owner has armed.  Persisted into the App Group so an alarm armed
    /// on the iPhone survives a relaunch, matching the macOS manager's
    /// `armedResetAlarmSectionIds`.
    private func persistArmedIds() {
        let armed = items.filter(\.isAlarmArmed).map(\.id)
        sharedDefaults.set(armed, forKey: "armedResetAlarmSectionIds")
    }
}
