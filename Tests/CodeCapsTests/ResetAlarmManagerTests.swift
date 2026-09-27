import XCTest
@testable import CodeCaps
import QuotaCore

/// Verifies quota reset alerts and alarms.
///
/// Specifically pins:
/// 1. Baseline initialization does not fire false alerts.
/// 2. Transition from exhausted to usable dispatches an alert.
/// 3. Controlling-cap rule: if an Antigravity 5-hour limit resets while the weekly limit
///    is still at 0% (masked), the alert is suppressed until all controlling caps clear.
/// 4. Plain multi-window providers suppress alerts if any non-masked window is still 0%.
/// 5. Explicitly user-armed alarms fire even if global notifications are disabled.
@MainActor
final class ResetAlarmManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.jays.codecaps.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeWindow(id: String, providerKey: String, remaining: Double, isFresh: Bool = true) -> QuotaWindowSnapshot {
        let window = QuotaWindow(
            id: id,
            provider: providerKey,
            providerKey: providerKey,
            providerLabel: providerKey,
            label: id,
            remainingPercent: remaining,
            remainingUnknown: false,
            occurredAt: ISO8601DateFormatter().string(from: Date())
        )
        return QuotaWindowSnapshot(window: window, now: Date())
    }

    private func makeSection(
        id: String,
        providerKey: String,
        title: String,
        windows: [QuotaWindowSnapshot],
        remainingPercent: Double?,
        maskedWindowIds: Set<String> = []
    ) -> DisplaySection {
        let platform = QuotaPlatformSection(
            providerKey: providerKey,
            providerLabel: title,
            expected: true,
            windows: windows
        )
        let poolKey = id.contains(":") ? String(id.split(separator: ":").last!) : nil
        return DisplaySection(
            id: id,
            providerKey: providerKey,
            title: title,
            platformTitle: title,
            section: platform,
            poolKey: poolKey,
            remainingPercent: remainingPercent,
            resetAt: nil,
            maskedWindowIds: maskedWindowIds
        )
    }

    // MARK: - Tests

    func testInitialEvaluationEstablishesBaselineWithoutAlerts() {
        let manager = ResetAlarmManager(defaults: defaults)
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        let exhaustedWindow = makeWindow(id: "claude-5h", providerKey: "anthropic", remaining: 0)
        let section = makeSection(
            id: "anthropic",
            providerKey: "anthropic",
            title: "Claude Code",
            windows: [exhaustedWindow],
            remainingPercent: 0
        )

        manager.evaluate(currentSections: [section])

        XCTAssertTrue(receivedAlerts.isEmpty, "Initial pass should establish baseline and not fire an alert")
        XCTAssertTrue(manager.isSectionExhausted(section))
        XCTAssertFalse(manager.isSectionUsable(section))
    }

    func testTransitionFromExhaustedToUsableDispatchesAlert() {
        let manager = ResetAlarmManager(defaults: defaults)
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        let exhaustedWindow = makeWindow(id: "claude-5h", providerKey: "anthropic", remaining: 0)
        let exhaustedSection = makeSection(
            id: "anthropic",
            providerKey: "anthropic",
            title: "Claude Code",
            windows: [exhaustedWindow],
            remainingPercent: 0
        )

        // Baseline pass
        manager.evaluate(currentSections: [exhaustedSection])
        XCTAssertTrue(receivedAlerts.isEmpty)

        // Second pass: quota has reset to 100%
        let resetWindow = makeWindow(id: "claude-5h", providerKey: "anthropic", remaining: 100)
        let resetSection = makeSection(
            id: "anthropic",
            providerKey: "anthropic",
            title: "Claude Code",
            windows: [resetWindow],
            remainingPercent: 100
        )

        manager.evaluate(currentSections: [resetSection])

        XCTAssertEqual(receivedAlerts.count, 1)
        XCTAssertEqual(receivedAlerts.first?.sectionId, "anthropic")
        XCTAssertEqual(receivedAlerts.first?.remainingPercent, 100)
        XCTAssertTrue(receivedAlerts.first?.title.contains("Claude Code") ?? false)
        // The payload carries the picked sound so a custom handler can
        // verify the Settings picker was honoured without inspecting
        // the (private) UNNotificationSound it eventually translates to.
        XCTAssertEqual(receivedAlerts.first?.sound, .systemDefault)
    }

    func testTransitionPicksUpPickedSound() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.alarmSound = .frog
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        let exhausted = makeSection(id: "anthropic", providerKey: "anthropic", title: "Claude Code",
                                    windows: [makeWindow(id: "claude-5h", providerKey: "anthropic", remaining: 0)],
                                    remainingPercent: 0)
        manager.evaluate(currentSections: [exhausted])

        let reset = makeSection(id: "anthropic", providerKey: "anthropic", title: "Claude Code",
                                windows: [makeWindow(id: "claude-5h", providerKey: "anthropic", remaining: 100)],
                                remainingPercent: 100)
        manager.evaluate(currentSections: [reset])

        XCTAssertEqual(receivedAlerts.first?.sound, .frog)
    }

    func testControllingCapSuppressionInAntigravityPool() {
        let manager = ResetAlarmManager(defaults: defaults)
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        let poolId = "google-antigravity:third-party"

        // Step 1: Both 5h and weekly limits are exhausted (0%).
        // Because weekly is 0%, the 5h window is masked.
        let w5hExhausted = makeWindow(id: "antigravity:third-party:5h", providerKey: "google-antigravity", remaining: 0)
        let wWeeklyExhausted = makeWindow(id: "antigravity:third-party:weekly", providerKey: "google-antigravity", remaining: 0)

        let initialSection = makeSection(
            id: poolId,
            providerKey: "google-antigravity",
            title: "Antigravity · Claude & GPT",
            windows: [w5hExhausted, wWeeklyExhausted],
            remainingPercent: 0,
            maskedWindowIds: [w5hExhausted.window.id]
        )

        manager.evaluate(currentSections: [initialSection])
        XCTAssertTrue(receivedAlerts.isEmpty)
        XCTAssertTrue(manager.isSectionExhausted(initialSection))
        XCTAssertFalse(manager.isSectionUsable(initialSection))

        // Step 2: 5-hour window resets to 100%, BUT weekly is STILL at 0%.
        // The 5-hour window remains masked by the weekly cap.
        let w5hReset = makeWindow(id: "antigravity:third-party:5h", providerKey: "google-antigravity", remaining: 100)
        let intermediateSection = makeSection(
            id: poolId,
            providerKey: "google-antigravity",
            title: "Antigravity · Claude & GPT",
            windows: [w5hReset, wWeeklyExhausted],
            remainingPercent: 0, // headline stays 0 because weekly is exhausted
            maskedWindowIds: [w5hReset.window.id]
        )

        manager.evaluate(currentSections: [intermediateSection])

        XCTAssertTrue(receivedAlerts.isEmpty, "Alert MUST be suppressed because weekly cap is still in effect")
        XCTAssertFalse(manager.isSectionUsable(intermediateSection))

        // Step 3: Weekly window also resets to 80%.
        // Both caps are now clear, and maskedWindowIds is empty.
        let wWeeklyReset = makeWindow(id: "antigravity:third-party:weekly", providerKey: "google-antigravity", remaining: 80)
        let finalSection = makeSection(
            id: poolId,
            providerKey: "google-antigravity",
            title: "Antigravity · Claude & GPT",
            windows: [w5hReset, wWeeklyReset],
            remainingPercent: 80,
            maskedWindowIds: []
        )

        manager.evaluate(currentSections: [finalSection])

        XCTAssertEqual(receivedAlerts.count, 1, "Alert should fire now that all controlling caps are cleared")
        XCTAssertEqual(receivedAlerts.first?.sectionId, poolId)
        XCTAssertEqual(receivedAlerts.first?.remainingPercent, 80)
    }

    func testUserArmedAlarmFiresEvenIfNotifyOnResetIsDisabled() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.notifyOnReset = false // Global reset alerts disabled
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        let sectionId = "openai"
        manager.toggleAlarm(for: sectionId)
        XCTAssertTrue(manager.isAlarmArmed(for: sectionId))

        let exhaustedWindow = makeWindow(id: "codex-fast", providerKey: "openai", remaining: 0)
        let exhaustedSection = makeSection(
            id: sectionId,
            providerKey: "openai",
            title: "Codex",
            windows: [exhaustedWindow],
            remainingPercent: 0
        )

        // Baseline pass
        manager.evaluate(currentSections: [exhaustedSection])
        XCTAssertTrue(receivedAlerts.isEmpty)

        // Reset pass
        let resetWindow = makeWindow(id: "codex-fast", providerKey: "openai", remaining: 90)
        let resetSection = makeSection(
            id: sectionId,
            providerKey: "openai",
            title: "Codex",
            windows: [resetWindow],
            remainingPercent: 90
        )

        manager.evaluate(currentSections: [resetSection])

        XCTAssertEqual(receivedAlerts.count, 1, "User-armed alarm must fire even when global notifyOnReset is false")
        XCTAssertFalse(manager.isAlarmArmed(for: sectionId), "Armed alarm should automatically disarm after firing")
    }

    func testSendTestNotification() async {
        let manager = ResetAlarmManager(defaults: defaults)
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        await manager.sendTestNotification()

        XCTAssertEqual(receivedAlerts.count, 1)
        XCTAssertEqual(receivedAlerts.first?.sectionId, "test")
        XCTAssertEqual(receivedAlerts.first?.sound, .systemDefault)
        XCTAssertEqual(manager.testNotificationOutcome, .sent)
    }

    /// The button used to request authorization and deliver in the same breath,
    /// so on a first run the add lost the race with the prompt and was dropped
    /// silently.  The plan has to ask first when nothing has been decided yet.
    func testPlannerAsksBeforeDeliveringWhenAuthorizationIsUndecided() {
        XCTAssertEqual(TestNotificationPlanner.action(for: .notDetermined), .requestThenDeliver)
    }

    /// A denied app cannot be delivered to at all.  Attempting it is the silent
    /// no-op that made the button look broken.
    func testPlannerRefusesToDeliverWhenDenied() {
        XCTAssertEqual(TestNotificationPlanner.action(for: .denied), .refuseDenied)
    }

    func testPlannerDeliversWhenAlreadyAuthorized() {
        XCTAssertEqual(TestNotificationPlanner.action(for: .authorized), .deliver)
        XCTAssertEqual(TestNotificationPlanner.action(for: .provisional), .deliver)
    }

    func testDeniedOutcomeExplainsTheFix() {
        XCTAssertTrue(TestNotificationOutcome.denied.isFailure)
        XCTAssertTrue(TestNotificationOutcome.denied.message.contains("System Settings"))
        XCTAssertFalse(TestNotificationOutcome.sent.isFailure)
        XCTAssertTrue(TestNotificationOutcome.failed("nope").isFailure)
    }

    func testPreviewChosenSoundInvokesCallbackForAudible() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.alarmSound = .glass
        var playedSounds = 0
        manager.onPlaySound = { playedSounds += 1 }

        manager.previewChosenSound()

        XCTAssertEqual(playedSounds, 1)
    }

    func testPreviewChosenSoundSkipsSilent() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.alarmSound = .silent
        var playedSounds = 0
        manager.onPlaySound = { playedSounds += 1 }

        manager.previewChosenSound()

        XCTAssertEqual(playedSounds, 0)
    }

    func testMigratesLegacySoundOnResetBool() {
        var domain = ""
        let store = UserDefaults(suiteName: domain + UUID().uuidString)!
        defer { store.removePersistentDomain(forName: store.dictionaryRepresentation().keys.first! as String) }
        store.set(true, forKey: "soundOnReset")

        let manager = ResetAlarmManager(defaults: store)
        XCTAssertEqual(manager.alarmSound, .systemDefault)
        // Migration writes the new key; the legacy key is left in place
        // (harmless) but the new key is the source of truth from now on.
        XCTAssertEqual(store.string(forKey: "alarmSound"), ResetAlarmSound.systemDefault.rawValue)
    }

    func testMigratesLegacySoundOffResetBoolToSilent() {
        let store = UserDefaults(suiteName: "codecaps.test.migrate.silent." + UUID().uuidString)!
        store.set(false, forKey: "soundOnReset")

        let manager = ResetAlarmManager(defaults: store)
        XCTAssertEqual(manager.alarmSound, .silent)
        XCTAssertEqual(store.string(forKey: "alarmSound"), ResetAlarmSound.silent.rawValue)
    }

    func testAlarmSoundPersistsAcrossInit() {
        let store = UserDefaults(suiteName: "codecaps.test.persist." + UUID().uuidString)!
        store.set(ResetAlarmSound.submarine.rawValue, forKey: "alarmSound")

        let manager = ResetAlarmManager(defaults: store)
        XCTAssertEqual(manager.alarmSound, .submarine)
    }
}
