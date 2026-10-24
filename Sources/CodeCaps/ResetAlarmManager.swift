import AppKit
import Foundation
import QuotaCore
import UserNotifications

/// The payload sent when a quota reset alert is triggered.
///
/// Carries the picked `ResetAlarmSound` so a test (and a future custom
/// delivery handler) can verify the alert honours the Dashboard picker
/// instead of trusting an external `UNNotificationSound` round-trip.
public struct ResetAlarmNotification: Equatable, Sendable {
    public let id: String
    /// The row the alarm belongs to: a provider key, or a pool-scoped key such
    /// as `google-antigravity:gemini`.
    public let providerId: String
    public let providerTitle: String
    public let title: String
    public let body: String
    public let remainingPercent: Int
    public let sound: ResetAlarmSound
    /// The windows whose reset this notification announces, largest first.
    public let windowLabels: [String]
    public let windowId: String?
    public let timestamp: Date
    public let isVendorReset: Bool
    /// The quota rose mid-cycle without reaching the level a vendor reset has
    /// to reach, so a change of plan is the likelier reason.
    public let isPlanChange: Bool
    /// The window the plan change happened on, when the notification carries
    /// one.  A group can hold a scheduled rollover and a plan change at once,
    /// and the owner's own window is the one that changed.
    public let planChangeWindowLabel: String?
    /// The level the plan change landed on, when the notification carries one.
    public let planChangeRemainingPercent: Int?

    public init(
        id: String,
        providerId: String,
        providerTitle: String = "",
        title: String,
        body: String,
        remainingPercent: Int,
        sound: ResetAlarmSound,
        windowLabels: [String],
        windowId: String?,
        timestamp: Date,
        isVendorReset: Bool = false,
        isPlanChange: Bool = false,
        planChangeWindowLabel: String? = nil,
        planChangeRemainingPercent: Int? = nil
    ) {
        self.id = id
        self.providerId = providerId
        self.providerTitle = providerTitle.isEmpty ? providerId.capitalized : providerTitle
        self.title = title
        self.body = body
        self.remainingPercent = remainingPercent
        self.sound = sound
        self.windowLabels = windowLabels
        self.windowId = windowId
        self.timestamp = timestamp
        self.isVendorReset = isVendorReset
        self.isPlanChange = isPlanChange
        self.planChangeWindowLabel = planChangeWindowLabel
        self.planChangeRemainingPercent = planChangeRemainingPercent
    }
}

/// A recorded reset alert, preserved in history so resets (especially
/// mid-cycle vendor resets) are visible to the owner in Usage History
/// and Console, even if system notification banners were missed or silenced.
public struct ResetAlertRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let providerKey: String
    public let providerTitle: String
    public let windowId: String?
    public let windowLabel: String
    public let remainingPercent: Int
    public let isVendorReset: Bool
    /// The quota rose mid-cycle without reaching the level a vendor reset has
    /// to reach, so a change of plan is the likelier reason.
    public let isPlanChange: Bool
    /// The window the plan change happened on.  The alert's own window is the
    /// group's first one, which is not always the window that changed.
    public let planChangeWindowLabel: String?
    /// The level the plan change landed on.
    public let planChangeRemainingPercent: Int?
    public let title: String
    public let body: String

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                providerKey: String,
                providerTitle: String,
                windowId: String?,
                windowLabel: String,
                remainingPercent: Int,
                isVendorReset: Bool,
                title: String,
                body: String,
                isPlanChange: Bool = false,
                planChangeWindowLabel: String? = nil,
                planChangeRemainingPercent: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.providerKey = providerKey
        self.providerTitle = providerTitle
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.remainingPercent = remainingPercent
        self.isVendorReset = isVendorReset
        self.title = title
        self.body = body
        self.isPlanChange = isPlanChange
        self.planChangeWindowLabel = planChangeWindowLabel
        self.planChangeRemainingPercent = planChangeRemainingPercent
    }

    /// Records written before the plan-change flag existed have no such key,
    /// and they must still load: the owner's reset history is worth more than
    /// the field that would have to be invented for them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        providerKey = try container.decode(String.self, forKey: .providerKey)
        providerTitle = try container.decode(String.self, forKey: .providerTitle)
        windowId = try container.decodeIfPresent(String.self, forKey: .windowId)
        windowLabel = try container.decode(String.self, forKey: .windowLabel)
        remainingPercent = try container.decode(Int.self, forKey: .remainingPercent)
        isVendorReset = try container.decode(Bool.self, forKey: .isVendorReset)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        isPlanChange = try container.decodeIfPresent(Bool.self, forKey: .isPlanChange) ?? false
        planChangeWindowLabel = try container.decodeIfPresent(String.self, forKey: .planChangeWindowLabel)
        planChangeRemainingPercent = try container.decodeIfPresent(Int.self, forKey: .planChangeRemainingPercent)
    }
}

/// What happened when the owner pressed "Send Test Notification".
///
/// The button used to be fire-and-forget: `UNUserNotificationCenter.add` was
/// called with no completion handler, so a rejected request produced no banner,
/// no sound, and no explanation.  A first run was always rejected, because the
/// authorization prompt had not been answered yet when the add was issued.
public enum TestNotificationOutcome: Equatable, Sendable {
    case sent
    /// Notifications are off for this app and the owner has to grant them in
    /// System Settings; nothing can be delivered until they do.
    case denied
    /// Delivery failed for a reason worth showing, e.g. the notification centre
    /// rejected the request.
    case failed(String)

    /// Owner-facing sentence for the Dashboard status line.
    public var message: String {
        switch self {
        case .sent:
            return "Test notification sent." + sentenceGap + "Check your notification centre."
        case .denied:
            return "Notifications are turned off for CodeCaps." + sentenceGap
                + "Turn them on in System Settings, then try again."
        case .failed(let reason):
            return "Could not send the test notification." + sentenceGap + reason
        }
    }

    public var isFailure: Bool {
        if case .sent = self { return false }
        return true
    }
}

/// The routing decision for a test send, kept pure so it is unit-testable
/// without a live `UNUserNotificationCenter`.
public enum TestNotificationAction: Equatable, Sendable {
    /// Authorization is already in hand, so deliver.
    case deliver
    /// Never asked; ask, and deliver only if the owner grants it.
    case requestThenDeliver
    /// Refused at the system level.  Delivering anyway is a silent no-op, which
    /// is exactly the bug this replaces.
    case refuseDenied
}

public struct TestNotificationPlanner {
    /// Maps an authorization status onto what a test send should do.
    ///
    /// `.ephemeral` is deliberately absent: it is iOS-only and this planner
    /// lives in the macOS app.  A status the compiler does not know about falls
    /// into `requestThenDeliver`, which is the safe answer.
    public static func action(for status: UNAuthorizationStatus) -> TestNotificationAction {
        switch status {
        case .notDetermined: return .requestThenDeliver
        case .denied: return .refuseDenied
        case .authorized, .provisional: return .deliver
        @unknown default: return .requestThenDeliver
        }
    }
}

/// The one reset-alarm model: which providers alarm, what they sound like, and
/// the notification that carries them.
///
/// Whether a reset is worth an alarm is decided by `ResetAlarmTracker` in
/// QuotaCore — the provider's largest window on every reset, a smaller window
/// only after it came within 20% of its cap — and this manager only adds the
/// owner's choices on top: every provider (All), or the providers picked one by
/// one with the bell beside each Glance row.
///
/// It replaces two older mechanisms that disagreed with each other: a global
/// "notify when an exhausted quota clears" switch, and one-shot bells armed per
/// row.  `init` migrates both into the new keys once.
@MainActor
public final class ResetAlarmManager: ObservableObject {
    /// UserDefaults keys, in one place so the migration tests can seed them.
    public enum Keys {
        public static let preferences = "usageAlertPreferences"
        public static let all = "resetAlarmAll"
        public static let providers = "resetAlarmProviders"
        public static let trackerState = "resetAlarmTrackerState"
        public static let sound = "alarmSound"
        public static let alertHistory = "resetAlertHistory"
        /// Read once, by the migration, and never written again.
        public static let legacyNotifyOnReset = "notifyOnReset"
        public static let legacyArmedSectionIds = "armedResetAlarmSectionIds"
        public static let legacySoundOnReset = "soundOnReset"
    }

    @Published public var preferences: UsageAlertPreferences {
        didSet {
            if !updatingLegacySound {
                let changed = UsageAlertKind.allCases.filter { preferences[$0].sound != oldValue[$0].sound }
                customizedSoundKinds.formUnion(changed.map(\.rawValue))
                defaults.set(customizedSoundKinds.sorted(), forKey: "usageAlertCustomizedSounds")
            }
            preferences.save(to: defaults, key: Keys.preferences)
        }
    }
    private var customizedSoundKinds: Set<String> = []
    private var updatingLegacySound = false
    private(set) var detectedResetHistory: [ResetAlertRecord] = []
    var onUsageDelivery: ((UsageAlertKind, String, String, UsageAlertOption) -> Void)?
    private var popupWindows: [NSWindow] = []
    private let defaults: UserDefaults

    /// Recorded reset alerts (scheduled and mid-cycle vendor resets),
    /// kept so the owner can review them in Usage History and Console.
    @Published public private(set) var alertHistory: [ResetAlertRecord] = []

    /// All: every provider's reset alarm is on, and Glance shows no per-row
    /// bells.  Off: only the providers in `enabledProviderIds` alarm.
    @Published public var allProvidersEnabled: Bool {
        didSet {
            defaults.set(allProvidersEnabled, forKey: Keys.all)
            if allProvidersEnabled && !oldValue { requestPermissionSoon() }
        }
    }

    /// The providers picked one by one.  Kept while All is on, so turning All
    /// off again restores the owner's own selection rather than a blank one.
    @Published public private(set) var enabledProviderIds: Set<String> {
        didSet { defaults.set(enabledProviderIds.sorted(), forKey: Keys.providers) }
    }

    /// Which sound the alarm plays.  Persisted as the raw value (a system
    /// sound name), so the migration just writes the new key and the
    /// legacy `soundOnReset` Bool is read once in `init`.  Defaults to
    /// `systemDefault` so a fresh install lands on the platform chime,
    /// matching the previous behaviour when `soundOnReset` was true.
    @Published public var alarmSound: ResetAlarmSound {
        didSet {
            defaults.set(alarmSound.rawValue, forKey: Keys.sound)
            updatingLegacySound = true
            defer { updatingLegacySound = false }
            for kind in UsageAlertKind.allCases where !customizedSoundKinds.contains(kind.rawValue) {
                var option = preferences[kind]
                option.sound = alarmSound
                preferences[kind] = option
            }
        }
    }

    /// Result of the most recent "Send Test Notification", or `nil` before the
    /// owner has ever pressed it.  Surfaced in the Dashboard so a refused send is
    /// visible instead of silent.
    @Published public private(set) var testNotificationOutcome: TestNotificationOutcome?

    /// Whether the system reports notifications as denied for this app.  Drives
    /// the "Open System Settings" affordance.
    @Published public private(set) var notificationsDenied = false

    /// The reset detector.  Its state is saved after every evaluation, so a
    /// restart or a Sparkle relaunch neither loses a reset that is due nor
    /// announces one twice.
    public private(set) var tracker: ResetAlarmTracker

    /// Injectable notification handler for unit testing.
    var onNotification: ((ResetAlarmNotification) -> Void)?

    /// Injectable sound player for unit testing.  Kept for the
    /// `sendTestNotification()` flow and for owners who set the picker
    /// to a system name we expose via `NSSound(named:)` even when
    /// notifications are off, so the preview button in the Dashboard still
    /// plays the chosen tone.
    var onPlaySound: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // One-time migration of the two old mechanisms.  The global switch
        // meant "alert on every provider", which is exactly All; the one-shot
        // bells meant "I want this row", which is exactly a per-provider pick.
        // A fresh install lands on All, like the old switch's default.
        let all: Bool
        if let saved = defaults.object(forKey: Keys.all) as? Bool {
            all = saved
        } else {
            all = defaults.object(forKey: Keys.legacyNotifyOnReset) as? Bool ?? true
            defaults.set(all, forKey: Keys.all)
        }
        self.allProvidersEnabled = all

        let providers: Set<String>
        if let saved = defaults.stringArray(forKey: Keys.providers) {
            providers = Set(saved)
        } else {
            providers = Set(defaults.stringArray(forKey: Keys.legacyArmedSectionIds) ?? [])
            defaults.set(providers.sorted(), forKey: Keys.providers)
        }
        self.enabledProviderIds = providers

        // One-time migration from the legacy sound boolean: an owner who
        // previously had `soundOnReset = true` lands on `.systemDefault`;
        // one who had turned it off lands on `.silent`.  Once the new key is
        // written, the legacy key is never read again.
        let resolved: ResetAlarmSound
        if let raw = defaults.string(forKey: Keys.sound),
           let migrated = ResetAlarmSound(rawValue: raw) {
            resolved = migrated
        } else if let legacySoundOn = defaults.object(forKey: Keys.legacySoundOnReset) as? Bool {
            resolved = legacySoundOn ? .systemDefault : .silent
            defaults.set(resolved.rawValue, forKey: Keys.sound)
        } else {
            resolved = .systemDefault
        }
        self.alarmSound = resolved
        self.preferences = UsageAlertPreferences.load(
            from: defaults, key: Keys.preferences, resetEnabled: true, resetSound: resolved,
            runawayEnabled: defaults.object(forKey: "burnRateAlertsEnabled") as? Bool ?? false)
        customizedSoundKinds = Set(defaults.stringArray(forKey: "usageAlertCustomizedSounds") ?? [])
        if let data = defaults.data(forKey: "detectedResetHistory"),
           let saved = try? JSONDecoder().decode([ResetAlertRecord].self, from: data) {
            detectedResetHistory = saved
        }

        if let data = defaults.data(forKey: Keys.alertHistory),
           let history = try? JSONDecoder().decode([ResetAlertRecord].self, from: data) {
            self.alertHistory = history
        } else {
            self.alertHistory = []
        }

        self.tracker = ResetAlarmTracker(
            state: ResetAlarmTrackerState.decoded(from: defaults.data(forKey: Keys.trackerState)))
        self.preferences.save(to: defaults, key: Keys.preferences)
    }

    // MARK: - Choices

    /// Explicit picker intent matters even when the selected sound equals the default.
    public func setSound(_ sound: ResetAlarmSound, for kind: UsageAlertKind) {
        customizedSoundKinds.insert(kind.rawValue)
        defaults.set(customizedSoundKinds.sorted(), forKey: "usageAlertCustomizedSounds")
        preferences[kind].sound = sound
    }

    /// Whether `providerId`'s reset alarm is on: every provider under All,
    /// otherwise only the ones picked.
    public func isAlarmEnabled(for providerId: String) -> Bool {
        allProvidersEnabled || enabledProviderIds.contains(providerId)
    }

    /// The owner's own pick for `providerId`, regardless of All.  This is what
    /// a per-row bell shows.
    public func isProviderSelected(_ providerId: String) -> Bool {
        enabledProviderIds.contains(providerId)
    }

    public func setProviderAlarm(_ enabled: Bool, for providerId: String) {
        guard enabled != enabledProviderIds.contains(providerId) else { return }
        if enabled {
            enabledProviderIds.insert(providerId)
            requestPermissionSoon()
        } else {
            enabledProviderIds.remove(providerId)
        }
    }

    public func toggleProviderAlarm(for providerId: String) {
        setProviderAlarm(!enabledProviderIds.contains(providerId), for: providerId)
    }

    public func playAlarmSound(_ sound: ResetAlarmSound) {
        guard sound.isAudible else { return }
        if let onPlaySound {
            onPlaySound()
            return
        }
        switch sound {
        case .systemDefault:
            NSSound.beep()
        default:
            NSSound(named: sound.rawValue)?.play()
        }
    }

    /// Plays the picked sound.  Used by the Dashboard "Preview" button so
    /// the owner can hear a sound before saving.
    public func previewChosenSound() {
        playAlarmSound(alarmSound)
    }

    private static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
            || NSClassFromString("XCTestCase") != nil
    }

    private static var canUseUserNotifications: Bool {
        guard !isRunningUnderTests else { return false }
        guard let id = Bundle.main.bundleIdentifier, !id.contains("xctest") else { return false }
        return true
    }

    // MARK: - Permission

    /// Asks for notification permission and reports whether it was granted.
    ///
    /// The old signature was a fire-and-forget completion handler that threw the
    /// answer away, so the very next `add` raced the prompt and lost.
    @discardableResult
    public func requestNotificationPermission() async -> Bool {
        guard Self.canUseUserNotifications else { return false }
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

    private func requestPermissionSoon() {
        guard Self.canUseUserNotifications else { return }
        Task { await requestNotificationPermission() }
    }

    /// Refreshes the denied flag from the system so the Dashboard affordance
    /// reflects reality on open rather than only after a failed send.
    public func refreshNotificationAuthorization() async {
        guard Self.canUseUserNotifications else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsDenied = (settings.authorizationStatus == .denied)
    }

    /// The URL that opens this app's notifications pane in System Settings.
    /// macOS has no deep link to one specific app, so this lands on the
    /// Notifications preference pane where CodeCaps is listed.
    public static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!

    // MARK: - Evaluation

    /// Feeds one refresh's readings through the tracker, saves its state, and
    /// sends a notification per provider for every alarm that is on.  Returns
    /// what was sent, for the tests.
    @discardableResult
    func evaluate(observations: [ResetAlarmObservation], now: Date = Date()) -> [ResetAlarmNotification] {
        let before = tracker.state
        let events = tracker.process(observations, now: now)
        if tracker.state != before, let data = tracker.state.encoded() {
            defaults.set(data, forKey: Keys.trackerState)
        }

        var order: [String] = []
        var byProvider: [String: [ResetAlarmEvent]] = [:]
        for event in events {
            let key = event.providerId + (event.isVendorReset ? "|vendor" : "|scheduled")
            if byProvider[key] == nil { order.append(key) }
            byProvider[key, default: []].append(event)
        }
        return order.compactMap { key in
            guard let group = byProvider[key], let event = group.first else { return nil }
            let providerId = event.providerId
            let content = Self.notificationContent(for: group)
            let isVendorReset = group.contains { $0.isVendorReset }
            // The two names are mutually exclusive, and the notification body
            // already resolves them in favour of the vendor reset.  The record
            // has to agree with the banner, or the same alarm is labelled two
            // different ways in two places.
            let isPlanChange = !isVendorReset && group.contains { $0.isPlanChange }
            // The plan change's own window and level, not the group's first
            // one: a group can hold a scheduled rollover and a plan change at
            // once, and the card has to describe the change the owner is being
            // asked to act on.
            let planChangeEvent = group.first(where: { $0.isPlanChange })
            let first = group.first
            let providerTitle = first?.providerTitle ?? providerId.capitalized
            let payload = ResetAlarmNotification(
                id: UUID().uuidString,
                providerId: providerId,
                providerTitle: providerTitle,
                title: content.title,
                body: content.body,
                remainingPercent: Int((first?.remainingPercent ?? 100).rounded()),
                sound: preferences[isVendorReset ? .vendorReset : .quotaReset].sound,
                windowLabels: content.windowLabels,
                windowId: first?.windowId,
                timestamp: now,
                isVendorReset: isVendorReset,
                isPlanChange: isPlanChange,
                planChangeWindowLabel: planChangeEvent.map { ResetAlarmMessage.normalizedWindowLabel(for: $0) },
                planChangeRemainingPercent: planChangeEvent?.remainingPercent.map { Int($0.rounded()) })
            deliver(payload)
            let kind: UsageAlertKind = isVendorReset ? .vendorReset : .quotaReset
            return isAlarmEnabled(for: providerId) && preferences[kind].enabled ? payload : nil
        }
    }

    /// The words of one provider's notification; shared with the iOS companion.
    static func notificationContent(for events: [ResetAlarmEvent]) -> (title: String, body: String, windowLabels: [String]) {
        ResetAlarmMessage.content(for: events)
    }

    // MARK: - Dispatch

    /// Resolves the picked sound into the `UNNotificationSound` value
    /// the alert carries.  `.silent` produces `nil` (the banner still
    /// appears; the alert is just muted); `.systemDefault` hands back
    /// the platform default chime; every other case builds the named
    /// system sound from `ResetAlarmSound.rawValue`.
    private func notificationSound(for sound: ResetAlarmSound) -> UNNotificationSound? {
        switch sound {
        case .silent:
            return nil
        case .systemDefault:
            return .default
        default:
            return UNNotificationSound(named: UNNotificationSoundName(sound.rawValue))
        }
    }

    private func deliver(_ payload: ResetAlarmNotification) {
        detectedResetHistory.insert(Self.record(for: payload), at: 0)
        detectedResetHistory = Array(detectedResetHistory.prefix(50))
        if let data = try? JSONEncoder().encode(detectedResetHistory) {
            defaults.set(data, forKey: "detectedResetHistory")
        }
        guard isAlarmEnabled(for: payload.providerId) else { return }
        let kind: UsageAlertKind = payload.isVendorReset ? .vendorReset : .quotaReset
        guard preferences[kind].enabled else { return }
        guard preferences[kind].notification || preferences[kind].popup else { return }
        appendAlertRecord(for: payload)
        if let onNotification {
            onNotification(payload)
            return
        }
        deliverUsageAlert(kind: kind, title: payload.title, body: payload.body,
                          identifier: payload.id,
                          navigation: AlertNavigation(providerKey: payload.providerId,
                                                      windowId: payload.windowId, timestamp: payload.timestamp))
    }

    /// The system plays notification audio.  Popup-only alerts play once locally.
    func deliverUsageAlert(kind: UsageAlertKind, title: String, body: String,
                           identifier: String, navigation: AlertNavigation? = nil) {
        let option = preferences[kind]
        guard option.enabled else { return }
        if let onUsageDelivery {
            onUsageDelivery(kind, title, body, option)
            return
        }
        if option.popup && !Self.isRunningUnderTests {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = body
            alert.addButton(withTitle: "Dismiss")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "CodeCaps Alert"
            window.center()
            popupWindows.append(window)
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { [weak self, weak window] _ in
                window?.close()
                self?.popupWindows.removeAll { $0 === window }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        if !option.notification {
            if option.popup { playAlarmSound(option.sound) }
            return
        }
        guard Self.canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = notificationSound(for: option.sound)
        content.userInfo = navigation?.userInfo ?? [:]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .denied {
                self?.notificationsDenied = true
                return
            }
            if settings.authorizationStatus == .notDetermined {
                guard await self?.requestNotificationPermission() == true else { return }
            }
            do { try await center.add(request) }
            catch { self?.testNotificationOutcome = .failed(error.localizedDescription) }
        }
    }

    public func appendAlertRecord(for payload: ResetAlarmNotification) {
        appendAlertRecord(Self.record(for: payload))
    }

    private static func record(for payload: ResetAlarmNotification) -> ResetAlertRecord {
        ResetAlertRecord(
            id: payload.id,
            timestamp: payload.timestamp,
            providerKey: payload.providerId,
            providerTitle: payload.providerTitle,
            windowId: payload.windowId,
            windowLabel: payload.windowLabels.first ?? "",
            remainingPercent: payload.remainingPercent,
            isVendorReset: payload.isVendorReset,
            title: payload.title,
            body: payload.body,
            isPlanChange: payload.isPlanChange,
            planChangeWindowLabel: payload.planChangeWindowLabel,
            planChangeRemainingPercent: payload.planChangeRemainingPercent
        )
    }

    public func appendAlertRecord(_ record: ResetAlertRecord) {
        alertHistory.insert(record, at: 0)
        if alertHistory.count > 50 {
            alertHistory = Array(alertHistory.prefix(50))
        }
        persistAlertHistory()
    }

    private func persistAlertHistory() {
        if let data = try? JSONEncoder().encode(alertHistory) {
            defaults.set(data, forKey: Keys.alertHistory)
        }
    }

    public func clearAlertHistory() {
        alertHistory.removeAll()
        detectedResetHistory.removeAll()
        defaults.removeObject(forKey: Keys.alertHistory)
        defaults.removeObject(forKey: "detectedResetHistory")
    }

    /// Delivers an opt-in runaway-usage alert through the same notification
    /// authorization path and selected sound as reset alerts.  Runaway alerts
    /// have their own identifier and do not consult reset-alarm selection.
    func deliverExhaustionWarning(platformLabel: String, headroom: String, sound: ResetAlarmSound) {
        guard Self.canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Quota Running Low: \(platformLabel)"
        content.body = "\(platformLabel) is about \(headroom) of quota left."
            + sentenceGap
            + "Wind up or hand off anything still running against it."
        content.sound = notificationSound(for: sound)
        let request = UNNotificationRequest(
            identifier: "codecaps.exhaustion.\(platformLabel).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .denied {
                self?.notificationsDenied = true
                return
            }
            if settings.authorizationStatus == .notDetermined {
                guard await self?.requestNotificationPermission() == true else { return }
            }
            do {
                try await center.add(request)
            } catch {
                self?.notificationsDenied = true
            }
        }
    }

    func deliverRunawayUsageAlert(_ payload: BurnRateNotification) {
        guard let first = payload.anomalies.first else { return }
        deliverUsageAlert(kind: first.kind == .vsPeak ? .runaway : .anomaly,
                          title: payload.title, body: payload.body, identifier: payload.identifier,
                          navigation: AlertNavigation(providerKey: first.providerKey,
                                                      windowId: first.windowId, timestamp: first.observedAt))
    }

    /// Sends an immediate test notification to verify notification delivery and sound.
    ///
    /// Now reports what happened.  The previous version requested authorization
    /// and delivered in the same breath, so on a first run the add was issued
    /// before the prompt was answered and was dropped without a word -- and a
    /// permanently denied app made the button inert forever.
    public func sendTestNotification() async {
        let title = "CodeCaps Reset Alert Test"
        let body = "Reset alerts and alarms are working properly." + sentenceGap + "Sound and banners active."

        // An injected handler owns delivery entirely, which is how the unit
        // tests exercise this without a notification centre.
        if let onNotification {
            onNotification(ResetAlarmNotification(
                id: UUID().uuidString,
                providerId: "test",
                title: title,
                body: body,
                remainingPercent: 100,
                sound: alarmSound,
                windowLabels: [],
                windowId: nil,
                timestamp: Date()
            ))
            testNotificationOutcome = .sent
            return
        }

        guard Self.canUseUserNotifications else {
            testNotificationOutcome = .failed(
                "Notifications are unavailable in this build of CodeCaps."
            )
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch TestNotificationPlanner.action(for: settings.authorizationStatus) {
        case .refuseDenied:
            notificationsDenied = true
            testNotificationOutcome = .denied
            return

        case .requestThenDeliver:
            guard await requestNotificationPermission() else {
                notificationsDenied = true
                testNotificationOutcome = .denied
                return
            }

        case .deliver:
            break
        }

        notificationsDenied = false
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = notificationSound(for: alarmSound)

        let request = UNNotificationRequest(
            identifier: "codecaps.test.\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            testNotificationOutcome = .sent
        } catch {
            testNotificationOutcome = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Readings for the tracker

/// How long one period of a window lasts, from its cadence token, its label,
/// or — for Cursor's plan, which carries neither — its provider.  `nil` when
/// nothing says, which the tracker treats as "not the largest window" unless
/// the provider has nothing better.
///
/// The shared resolver answers, so the tracker's period is the same period the
/// row's caption names and the row's marker is drawn for.
func quotaWindowPeriodSeconds(_ snapshot: QuotaWindowSnapshot) -> TimeInterval? {
    if let period = glanceWindowPeriod(snapshot) {
        return ResetAlarmCadence.seconds(for: period)
    }
    let token = (snapshot.window.window ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    switch token {
    case "session": return 5 * 3_600
    default: return nil
    }
}

/// The tracker's view of one row: one observation per quota window, skipping
/// supplementary allowances.  A masked window reports no percentage, because
/// its percentage must not be believed.
func resetAlarmObservations(for row: DisplaySection, scope: String) -> [ResetAlarmObservation] {
    row.section.windows
        .filter { !$0.window.isSupplementaryVideoQuota }
        .map { snapshot in
            ResetAlarmObservation(
                scope: scope,
                providerId: row.id,
                providerTitle: row.title,
                windowId: snapshot.window.id,
                windowLabel: glanceMeterCaption(snapshot),
                periodSeconds: quotaWindowPeriodSeconds(snapshot),
                resetAt: snapshot.resetAt,
                remainingPercent: row.isMasked(snapshot) ? nil : snapshot.remainingPercent,
                observedAt: snapshot.observedAt,
                identity: snapshot.window.accountKey)
        }
}
