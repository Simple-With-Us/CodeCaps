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
    public let sectionId: String
    public let title: String
    public let body: String
    public let remainingPercent: Int
    public let sound: ResetAlarmSound
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

/// Manages reset alerts and alarms when exhausted quotas clear.
///
/// Ensures that an alert is only fired when ALL controlling quotas for a model
/// or platform are clear and the model can actually be used again.  For example,
/// if an Antigravity 5-hour window resets while the weekly limit is still at 0%
/// (exhausted/masked), the alert is suppressed until the weekly cap also clears.
@MainActor
public final class ResetAlarmManager: ObservableObject {
    private let defaults: UserDefaults

    @Published public var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: "notifyOnReset") }
    }

    /// Which sound the alarm plays.  Persisted as the raw value (a system
    /// sound name), so the migration just writes the new key and the
    /// legacy `soundOnReset` Bool is read once in `init`.  Defaults to
    /// `systemDefault` so a fresh install lands on the platform chime,
    /// matching the previous behaviour when `soundOnReset` was true.
    @Published public var alarmSound: ResetAlarmSound {
        didSet { defaults.set(alarmSound.rawValue, forKey: "alarmSound") }
    }

    @Published public var armedSectionIds: Set<String> {
        didSet { defaults.set(Array(armedSectionIds), forKey: "armedResetAlarmSectionIds") }
    }

    /// Result of the most recent "Send Test Notification", or `nil` before the
    /// owner has ever pressed it.  Surfaced in Settings so a refused send is
    /// visible instead of silent.
    @Published public private(set) var testNotificationOutcome: TestNotificationOutcome?

    /// Whether the system reports notifications as denied for this app.  Drives
    /// the "Open System Settings" affordance.
    @Published public private(set) var notificationsDenied = false

    /// The IDs of sections observed as exhausted/blocked on previous evaluations.
    public private(set) var exhaustedSectionIds: Set<String> = []

    /// Whether this manager has performed its initial baseline pass.
    private var hasInitialized = false

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
        self.notifyOnReset = defaults.object(forKey: "notifyOnReset") as? Bool ?? true
        // One-time migration from the legacy boolean: a fresh owner who
        // previously had `soundOnReset = true` lands on `.systemDefault`;
        // one who had turned it off lands on `.silent`.  Once the new key
        // is written, the legacy key is never read again.  Resolve the
        // value into a local first because reading `self.alarmSound`
        // inside `didSet` before every stored property is initialised
        // makes Swift reject the init.
        let resolved: ResetAlarmSound
        if let raw = defaults.string(forKey: "alarmSound"),
           let migrated = ResetAlarmSound(rawValue: raw) {
            resolved = migrated
        } else if let legacySoundOn = defaults.object(forKey: "soundOnReset") as? Bool {
            resolved = legacySoundOn ? .systemDefault : .silent
            defaults.set(resolved.rawValue, forKey: "alarmSound")
        } else {
            resolved = .systemDefault
        }
        self.alarmSound = resolved
        let savedArmed = defaults.stringArray(forKey: "armedResetAlarmSectionIds") ?? []
        self.armedSectionIds = Set(savedArmed)
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

    // MARK: - Arming

    public func isAlarmArmed(for sectionId: String) -> Bool {
        armedSectionIds.contains(sectionId)
    }

    public func toggleAlarm(for sectionId: String) {
        if armedSectionIds.contains(sectionId) {
            armedSectionIds.remove(sectionId)
        } else {
            armedSectionIds.insert(sectionId)
            Task { await requestNotificationPermission() }
        }
    }

    // MARK: - Usability Evaluation

    /// Whether a section is currently exhausted or blocked.
    func isSectionExhausted(_ section: DisplaySection) -> Bool {
        // If headline remaining percent is zero, it is definitely exhausted.
        if let pct = section.remainingPercent, pct <= 0 {
            return true
        }

        // For Antigravity pools, if any window is masked, the weekly cap is exhausted.
        if !section.maskedWindowIds.isEmpty {
            return true
        }

        // Check all primary fresh windows in this section.
        let activeWindows = section.section.windows.filter {
            $0.isFresh && !$0.window.isSupplementaryVideoQuota && !section.isMasked($0)
        }
        guard !activeWindows.isEmpty else { return false }

        return activeWindows.contains { ($0.remainingPercent ?? 100) <= 0 }
    }

    /// Whether a section can genuinely be used again (all controlling caps cleared).
    func isSectionUsable(_ section: DisplaySection) -> Bool {
        // Headline remaining percent must be present and greater than zero.
        guard let headline = section.remainingPercent, headline > 0 else {
            return false
        }

        // Antigravity: if weekly is exhausted, 5-hour is masked, so maskedWindowIds must be empty.
        guard section.maskedWindowIds.isEmpty else {
            return false
        }

        // Every unmasked active window must have positive remaining percentage.
        let activeWindows = section.section.windows.filter {
            $0.isFresh && !$0.window.isSupplementaryVideoQuota && !section.isMasked($0)
        }
        guard !activeWindows.isEmpty else {
            return headline > 0
        }

        return activeWindows.allSatisfy { ($0.remainingPercent ?? 100) > 0 }
    }

    // MARK: - Evaluation Cycle

    /// Evaluates current sections against previous states and dispatches alerts
    /// when a previously exhausted or user-armed model becomes usable again.
    func evaluate(currentSections: [DisplaySection], now: Date = Date()) {
        var currentExhausted: Set<String> = []

        for section in currentSections {
            let blocked = isSectionExhausted(section)
            let usable = isSectionUsable(section)

            if blocked {
                currentExhausted.insert(section.id)
            }

            // On initial run, record baseline exhaustion without triggering alerts.
            guard hasInitialized else { continue }

            let wasExhausted = exhaustedSectionIds.contains(section.id)
            let isArmed = armedSectionIds.contains(section.id)

            // Alert triggers when a previously exhausted or user-armed model is now usable
            // AND all controlling caps are completely clear.
            if usable && (wasExhausted || isArmed) {
                if notifyOnReset || isArmed {
                    dispatchAlert(for: section)
                }
                // Clear the one-shot alarm if it was armed.
                armedSectionIds.remove(section.id)
            }
        }

        exhaustedSectionIds = currentExhausted
        hasInitialized = true
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

    private func dispatchAlert(for section: DisplaySection) {
        let pct = Int((section.remainingPercent ?? 100).rounded())
        let title = "Quota Reset: \(section.title)"
        let body = "All quotas have cleared (\(pct)% remaining)." + sentenceGap + "Ready to use again."

        let payload = ResetAlarmNotification(
            id: UUID().uuidString,
            sectionId: section.id,
            title: title,
            body: body,
            remainingPercent: pct,
            sound: alarmSound
        )

        // Deliver via custom test handler if installed
        if let onNotification {
            onNotification(payload)
        } else if Self.canUseUserNotifications {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = notificationSound(for: alarmSound)

            let request = UNNotificationRequest(
                identifier: "codecaps.reset.\(section.id).\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            // A real alert that the centre refuses is worth recording for the
            // same reason the test button is: a silent no-op reads as "the app
            // is broken" when it is actually a permission problem.
            Task { [weak self] in
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    self?.testNotificationOutcome = .failed(error.localizedDescription)
                }
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
                sectionId: "test",
                title: title,
                body: body,
                remainingPercent: 100,
                sound: alarmSound
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
