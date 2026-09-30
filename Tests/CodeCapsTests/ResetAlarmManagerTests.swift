import XCTest
@testable import CodeCaps
import QuotaCore

/// Verifies the reset-alarm model the Glance header and rows drive: All or
/// per-provider choices, their persistence and the migration from the two old
/// mechanisms, and the notifications the tracker's decisions turn into.
///
/// The rules themselves (largest window always, smaller windows only near the
/// cap) are pinned in `QuotaCoreTests/ResetAlarmTrackerTests`.
@MainActor
final class ResetAlarmManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

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

    private func week(_ provider: String, resetAt: Date, remaining: Double, at now: Date,
                      title: String = "Claude") -> ResetAlarmObservation {
        ResetAlarmObservation(scope: "local", providerId: provider, providerTitle: title,
                              windowId: "\(provider):7d", windowLabel: "7d", periodSeconds: 7 * 86_400,
                              resetAt: resetAt, remainingPercent: remaining, observedAt: now)
    }

    private func fiveHour(_ provider: String, resetAt: Date, remaining: Double, at now: Date,
                          title: String = "Claude") -> ResetAlarmObservation {
        ResetAlarmObservation(scope: "local", providerId: provider, providerTitle: title,
                              windowId: "\(provider):5h", windowLabel: "5h", periodSeconds: 5 * 3_600,
                              resetAt: resetAt, remainingPercent: remaining, observedAt: now)
    }

    /// Runs one weekly reset for each of `providers` through `manager`.
    private func runWeeklyReset(_ manager: ResetAlarmManager, providers: [String]) -> [ResetAlarmNotification] {
        let end = t0.addingTimeInterval(3_600)
        manager.evaluate(observations: providers.map { week($0, resetAt: end, remaining: 60, at: t0) }, now: t0)
        let later = end.addingTimeInterval(600)
        return manager.evaluate(
            observations: providers.map { week($0, resetAt: end.addingTimeInterval(7 * 86_400), remaining: 100, at: later) },
            now: later)
    }

    // MARK: - Choices and persistence

    func testFreshInstallTurnsAllOnWithNoProvidersPicked() {
        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(manager.allProvidersEnabled)
        XCTAssertTrue(manager.enabledProviderIds.isEmpty)
        XCTAssertTrue(manager.isAlarmEnabled(for: "anthropic"))
        XCTAssertEqual(defaults.object(forKey: ResetAlarmManager.Keys.all) as? Bool, true)
    }

    func testAllAndEachProviderChoicePersistAcrossLaunches() {
        let first = ResetAlarmManager(defaults: defaults)
        first.allProvidersEnabled = false
        first.setProviderAlarm(true, for: "anthropic")
        first.setProviderAlarm(true, for: "google-antigravity:gemini")
        first.toggleProviderAlarm(for: "cursor")
        first.toggleProviderAlarm(for: "cursor")

        let relaunched = ResetAlarmManager(defaults: defaults)
        XCTAssertFalse(relaunched.allProvidersEnabled)
        XCTAssertEqual(relaunched.enabledProviderIds, ["anthropic", "google-antigravity:gemini"])
        XCTAssertTrue(relaunched.isAlarmEnabled(for: "anthropic"))
        XCTAssertFalse(relaunched.isAlarmEnabled(for: "cursor"))
        XCTAssertFalse(relaunched.isAlarmEnabled(for: "google-antigravity:third-party"))
    }

    func testTurningAllOnKeepsThePerProviderPicksForLater() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.allProvidersEnabled = false
        manager.setProviderAlarm(true, for: "openai")
        manager.allProvidersEnabled = true
        XCTAssertTrue(manager.isAlarmEnabled(for: "cursor"), "All covers every provider")

        let relaunched = ResetAlarmManager(defaults: defaults)
        relaunched.allProvidersEnabled = false
        XCTAssertEqual(relaunched.enabledProviderIds, ["openai"], "turning All off restores the owner's own picks")
    }

    func testMigratesTheOldGlobalSwitchAndArmedBells() {
        // An owner who had turned the global switch off and armed two rows.
        defaults.set(false, forKey: ResetAlarmManager.Keys.legacyNotifyOnReset)
        defaults.set(["anthropic", "google-antigravity:third-party"],
                     forKey: ResetAlarmManager.Keys.legacyArmedSectionIds)

        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertFalse(manager.allProvidersEnabled)
        XCTAssertEqual(manager.enabledProviderIds, ["anthropic", "google-antigravity:third-party"])
        XCTAssertEqual(defaults.object(forKey: ResetAlarmManager.Keys.all) as? Bool, false)
        XCTAssertEqual(defaults.stringArray(forKey: ResetAlarmManager.Keys.providers),
                       ["anthropic", "google-antigravity:third-party"])
    }

    func testMigratesTheOldDefaultOnSwitchToAll() {
        defaults.set(true, forKey: ResetAlarmManager.Keys.legacyNotifyOnReset)
        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(manager.allProvidersEnabled)
    }

    func testMigrationRunsOnceAndNeverOverridesTheNewKeys() {
        defaults.set(false, forKey: ResetAlarmManager.Keys.legacyNotifyOnReset)
        defaults.set(["openai"], forKey: ResetAlarmManager.Keys.legacyArmedSectionIds)
        let first = ResetAlarmManager(defaults: defaults)
        first.allProvidersEnabled = true
        first.setProviderAlarm(false, for: "openai")

        // The legacy keys are still on disk; they must not win again.
        let relaunched = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(relaunched.allProvidersEnabled)
        XCTAssertTrue(relaunched.enabledProviderIds.isEmpty)
    }

    // MARK: - Gating and delivery

    func testAllOnAlarmsEveryProvider() {
        let manager = ResetAlarmManager(defaults: defaults)
        var received: [ResetAlarmNotification] = []
        manager.onNotification = { received.append($0) }

        let sent = runWeeklyReset(manager, providers: ["anthropic", "openai"])
        XCTAssertEqual(sent.map(\.providerId), ["anthropic", "openai"])
        XCTAssertEqual(received.count, 2)
    }

    func testAllOffAlarmsOnlyThePickedProviders() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.allProvidersEnabled = false
        manager.setProviderAlarm(true, for: "openai")
        var received: [ResetAlarmNotification] = []
        manager.onNotification = { received.append($0) }

        _ = runWeeklyReset(manager, providers: ["anthropic", "openai"])
        XCTAssertEqual(received.map(\.providerId), ["openai"])
    }

    func testAPickedProviderStaysPickedAfterItRings() {
        // The old bells were one-shot and disarmed themselves; a provider pick
        // is a standing choice.
        let manager = ResetAlarmManager(defaults: defaults)
        manager.allProvidersEnabled = false
        manager.setProviderAlarm(true, for: "openai")
        manager.onNotification = { _ in }
        _ = runWeeklyReset(manager, providers: ["openai"])
        XCTAssertTrue(manager.isProviderSelected("openai"))
    }

    func testTrackerStateIsSavedSoARelaunchDoesNotRefire() {
        let manager = ResetAlarmManager(defaults: defaults)
        var received: [ResetAlarmNotification] = []
        manager.onNotification = { received.append($0) }
        _ = runWeeklyReset(manager, providers: ["anthropic"])
        XCTAssertEqual(received.count, 1)
        XCTAssertNotNil(defaults.data(forKey: ResetAlarmManager.Keys.trackerState))

        let relaunched = ResetAlarmManager(defaults: defaults)
        relaunched.onNotification = { received.append($0) }
        let later = t0.addingTimeInterval(3 * 3_600)
        relaunched.evaluate(observations: [week("anthropic", resetAt: t0.addingTimeInterval(3_600 + 7 * 86_400),
                                                remaining: 99, at: later)], now: later)
        XCTAssertEqual(received.count, 1, "the week that already rang must not ring again after a relaunch")
    }

    func testAPendingResetSurvivesARelaunch() {
        let first = ResetAlarmManager(defaults: defaults)
        first.onNotification = { _ in XCTFail("nothing has reset yet") }
        let end = t0.addingTimeInterval(3_600)
        first.evaluate(observations: [week("anthropic", resetAt: end, remaining: 40, at: t0)], now: t0)

        // The week resets while the app is down.
        let relaunched = ResetAlarmManager(defaults: defaults)
        var received: [ResetAlarmNotification] = []
        relaunched.onNotification = { received.append($0) }
        let later = end.addingTimeInterval(2 * 3_600)
        relaunched.evaluate(observations: [week("anthropic", resetAt: end.addingTimeInterval(7 * 86_400),
                                                remaining: 100, at: later)], now: later)
        XCTAssertEqual(received.count, 1)
    }

    // MARK: - Notification words

    func testWeeklyResetNotificationSaysANewWeekBegan() {
        let manager = ResetAlarmManager(defaults: defaults)
        manager.alarmSound = .frog
        var received: [ResetAlarmNotification] = []
        manager.onNotification = { received.append($0) }
        _ = runWeeklyReset(manager, providers: ["anthropic"])

        let alert = try? XCTUnwrap(received.first)
        XCTAssertEqual(alert?.title, "Quota Reset: Claude")
        XCTAssertEqual(alert?.body, "The 7d window reset." + sentenceGap + "A new week of quota is available.")
        XCTAssertEqual(alert?.windowLabels, ["7d"])
        XCTAssertEqual(alert?.remainingPercent, 100)
        // The payload carries the picked sound so a custom handler can verify
        // the Settings picker was honoured.
        XCTAssertEqual(alert?.sound, .frog)
    }

    func testNearCapResetNotificationSaysHowCloseItCame() {
        let event = ResetAlarmEvent(scope: "local", providerId: "anthropic", providerTitle: "Claude",
                                    windowId: "5h", windowLabel: "5h", periodSeconds: 5 * 3_600,
                                    endedPeriodResetAt: t0, remainingPercent: 100,
                                    reason: .nearCap(minimumRemaining: 8))
        let content = ResetAlarmManager.notificationContent(for: [event])
        XCTAssertEqual(content.body, "The 5h window reset after reaching 8% remaining." + sentenceGap + "Ready to use again.")

        var capped = event
        capped.reason = .nearCap(minimumRemaining: 0)
        XCTAssertEqual(ResetAlarmManager.notificationContent(for: [capped]).body,
                       "The 5h window reset after hitting its cap." + sentenceGap + "Ready to use again.")
    }

    func testMonthlyAndCombinedResetsShareOneNotification() {
        let month = ResetAlarmEvent(scope: "local", providerId: "cursor", providerTitle: "Cursor",
                                    windowId: "plan", windowLabel: "1m", periodSeconds: 30 * 86_400,
                                    endedPeriodResetAt: t0, remainingPercent: 100, reason: .newPeriod)
        XCTAssertEqual(ResetAlarmManager.notificationContent(for: [month]).body,
                       "The 1m window reset." + sentenceGap + "A new month of quota is available.")

        let weekEvent = ResetAlarmEvent(scope: "local", providerId: "anthropic", providerTitle: "Claude",
                                        windowId: "7d", windowLabel: "7d", periodSeconds: 7 * 86_400,
                                        endedPeriodResetAt: t0, remainingPercent: 100, reason: .newPeriod)
        let fiveEvent = ResetAlarmEvent(scope: "local", providerId: "anthropic", providerTitle: "Claude",
                                        windowId: "5h", windowLabel: "5h", periodSeconds: 5 * 3_600,
                                        endedPeriodResetAt: t0, remainingPercent: 100,
                                        reason: .nearCap(minimumRemaining: 3))
        let combined = ResetAlarmManager.notificationContent(for: [weekEvent, fiveEvent])
        XCTAssertEqual(combined.body, "The 7d and 5h windows reset." + sentenceGap + "A new week of quota is available.")
        XCTAssertEqual(combined.windowLabels, ["7d", "5h"])
    }

    func testBothWindowsResettingTogetherSendOneNotification() {
        let manager = ResetAlarmManager(defaults: defaults)
        var received: [ResetAlarmNotification] = []
        manager.onNotification = { received.append($0) }
        let end = t0.addingTimeInterval(3_600)
        manager.evaluate(observations: [
            week("anthropic", resetAt: end, remaining: 30, at: t0),
            fiveHour("anthropic", resetAt: end, remaining: 2, at: t0),
        ], now: t0)
        let later = end.addingTimeInterval(60)
        manager.evaluate(observations: [
            week("anthropic", resetAt: end.addingTimeInterval(7 * 86_400), remaining: 100, at: later),
            fiveHour("anthropic", resetAt: later.addingTimeInterval(5 * 3_600), remaining: 100, at: later),
        ], now: later)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.windowLabels, ["7d", "5h"])
    }

    // MARK: - Readings handed to the tracker

    func testObservationsCoverEveryWindowWithItsPeriodAndMaskedWindowsReportNoPercentage() {
        let iso = ISO8601DateFormatter()
        func window(_ id: String, _ label: String, _ token: String?, _ remaining: Double) -> QuotaWindowSnapshot {
            QuotaWindowSnapshot(window: QuotaWindow(
                id: id, provider: "Antigravity", providerKey: "google-antigravity", label: label,
                remainingPercent: remaining, resetAt: iso.string(from: t0.addingTimeInterval(3_600)),
                window: token, occurredAt: iso.string(from: t0)), now: t0)
        }
        let five = window("ag:tp:5h", "Third-Party · 5-hour", "5h", 80)
        let weekly = window("ag:tp:weekly", "Third-Party · Weekly", "weekly", 0)
        let row = DisplaySection(
            id: "google-antigravity:third-party", providerKey: "google-antigravity",
            title: "Antigravity · Third-Party", platformTitle: "Antigravity",
            section: QuotaPlatformSection(providerKey: "google-antigravity", providerLabel: "Antigravity",
                                          expected: true, windows: [five, weekly]),
            poolKey: "third-party", remainingPercent: 0, resetAt: nil, maskedWindowIds: ["ag:tp:5h"])

        let observations = resetAlarmObservations(for: row, scope: "local")
        XCTAssertEqual(observations.map(\.windowLabel), ["5h", "7d"])
        XCTAssertEqual(observations.map(\.periodSeconds), [5 * 3_600, 7 * 86_400])
        XCTAssertEqual(observations.map(\.providerId), ["google-antigravity:third-party", "google-antigravity:third-party"])
        XCTAssertNil(observations[0].remainingPercent, "a masked 5h percentage must not be believed")
        XCTAssertEqual(observations[1].remainingPercent, 0)
    }

    func testCursorPlanIsAMonthLongPeriod() {
        let iso = ISO8601DateFormatter()
        let plan = QuotaWindowSnapshot(window: QuotaWindow(
            id: "local-mac:cursor:plan", provider: "Cursor", providerKey: "cursor", label: "Included plan",
            remainingPercent: 40, window: "billing-cycle", occurredAt: iso.string(from: t0)), now: t0)
        XCTAssertEqual(quotaWindowPeriodSeconds(plan), 30 * 86_400)
        XCTAssertEqual(glanceMeterCaption(plan), "1m")
    }

    func testSendTestNotification() async {
        let manager = ResetAlarmManager(defaults: defaults)
        var receivedAlerts: [ResetAlarmNotification] = []
        manager.onNotification = { receivedAlerts.append($0) }

        await manager.sendTestNotification()

        XCTAssertEqual(receivedAlerts.count, 1)
        XCTAssertEqual(receivedAlerts.first?.providerId, "test")
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
