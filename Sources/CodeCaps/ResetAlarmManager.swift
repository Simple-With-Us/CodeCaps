import AppKit
import Foundation
import QuotaCore
import UserNotifications

/// The payload sent when a quota reset alert is triggered.
///
/// Carries the picked `ResetAlarmSound` so a test (and a future custom
/// delivery handler) can verify the alert honours the Settings picker
/// instead of trusting an external `UNNotificationSound` round-trip.
public struct ResetAlarmNotification: Equatable, Sendable {
    public let id: String
    /// The row the alarm belongs to: a provider key, or a pool-scoped key such
    /// as `google-antigravity:gemini`.
    public let providerId: String
    public let title: String
    public let body: String
    public let remainingPercent: Int
    public let sound: ResetAlarmSound
    /// The windows whose reset this notification announces, largest first.
    public let windowLabels: [String]
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

    /// Owner-facing sentence for the Settings status line.
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
        public static let all = "resetAlarmAll"
        public static let providers = "resetAlarmProviders"
        public static let trackerState = "resetAlarmTrackerState"
        public static let sound = "alarmSound"
        /// Read once, by the migration, and never written again.
        public static let legacyNotifyOnReset = "notifyOnReset"
        public static let legacyArmedSectionIds = "armedResetAlarmSectionIds"
        public static let legacySoundOnReset = "soundOnReset"
    }

    private let defaults: UserDefaults

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
        didSet { defaults.set(alarmSound.rawValue, forKey: Keys.sound) }
    }

    /// Result of the most recent "Send Test Notification", or `nil` before the
    /// owner has ever pressed it.  Surfaced in Settings so a refused send is
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
    /// notifications are off, so the preview button in Settings still
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

        self.tracker = ResetAlarmTracker(
            state: ResetAlarmTrackerState.decoded(from: defaults.data(forKey: Keys.trackerState)))
    }

    // MARK: - Choices

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

    /// Plays the picked sound.  Used by the Settings "Preview" button so
    /// the owner can hear a sound before saving; called both with an
    /// armed payload (during a real reset alert) and with no payload at
    /// all (during a preview), so this is parameterless and emits via
    /// `NSSound(named:)`.  `.silent` and `.systemDefault` are special-cased
    /// so a preview of `Default chime` does not double-fire alongside the
    /// system chime the notification would deliver.
    public func previewChosenSound() {
        let sound = alarmSound
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

    /// Refreshes the denied flag from the system so the Settings affordance
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
        for event in events where isAlarmEnabled(for: event.providerId) {
            if byProvider[event.providerId] == nil { order.append(event.providerId) }
            byProvider[event.providerId, default: []].append(event)
        }
        return order.compactMap { providerId in
            guard let group = byProvider[providerId], !group.isEmpty else { return nil }
            let content = Self.notificationContent(for: group)
            let payload = ResetAlarmNotification(
                id: UUID().uuidString,
                providerId: providerId,
                title: content.title,
                body: content.body,
                remainingPercent: Int((group.first?.remainingPercent ?? 100).rounded()),
                sound: alarmSound,
                windowLabels: content.windowLabels)
            deliver(payload)
            return payload
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
        // Deliver via custom test handler if installed
        if let onNotification {
            onNotification(payload)
            return
        }
        guard Self.canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = notificationSound(for: payload.sound)

        let request = UNNotificationRequest(
            identifier: "codecaps.reset.\(payload.providerId).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        // A real alert that the centre refuses is worth recording for the
        // same reason the test button is: a silent no-op reads as "the app
        // is broken" when it is actually a permission problem.  All is on by
        // default, so the first alarm may be the first time anyone asked.
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard await self?.requestNotificationPermission() == true else { return }
            }
            do {
                try await center.add(request)
            } catch {
                self?.testNotificationOutcome = .failed(error.localizedDescription)
            }
        }
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
                windowLabels: []
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
func quotaWindowPeriodSeconds(_ snapshot: QuotaWindowSnapshot) -> TimeInterval? {
    let token = (snapshot.window.window ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = glanceDurationSeconds(token) { return seconds }
    if glanceIsMonthly(snapshot) { return 30 * 86_400 }
    if let parsed = WindowPacing.parseDurationSeconds(token: snapshot.window.window, label: snapshot.window.label) {
        return parsed
    }
    switch token {
    case "session": return 5 * 3_600
    case "daily", "day": return 86_400
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
