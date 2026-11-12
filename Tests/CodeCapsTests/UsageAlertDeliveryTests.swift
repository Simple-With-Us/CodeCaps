import XCTest
import QuotaCore
@testable import CodeCaps

@MainActor
final class UsageAlertDeliveryTests: XCTestCase {
    func testExplicitDefaultCategorySoundSurvivesGlobalPickerAndRelaunch() {
        let name = "UsageAlertExplicitSoundTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ResetAlarmManager(defaults: defaults)
        manager.setSound(.systemDefault, for: .runaway)
        manager.alarmSound = .frog
        XCTAssertEqual(manager.preferences[.runaway].sound, .systemDefault)
        let relaunched = ResetAlarmManager(defaults: defaults)
        relaunched.alarmSound = .submarine
        XCTAssertEqual(relaunched.preferences[.runaway].sound, .systemDefault)
    }

    func testDisabledResetDetectionExportsWithoutLocalHistory() {
        let name = "UsageAlertResetHistoryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ResetAlarmManager(defaults: defaults)
        manager.allProvidersEnabled = false
        let now = Date()
        let reset = now.addingTimeInterval(3_600)
        func observation(at date: Date, resetAt: Date, remaining: Double) -> ResetAlarmObservation {
            .init(scope: "local", providerId: "anthropic", providerTitle: "Claude",
                  windowId: "anthropic:7d", windowLabel: "7d", periodSeconds: 7 * 86_400,
                  resetAt: resetAt, remainingPercent: remaining, observedAt: date)
        }
        manager.evaluate(observations: [observation(at: now, resetAt: reset, remaining: 40)], now: now)
        manager.evaluate(observations: [observation(at: reset.addingTimeInterval(600),
                                                   resetAt: reset.addingTimeInterval(7 * 86_400), remaining: 100)],
                         now: reset.addingTimeInterval(600))
        XCTAssertTrue(manager.alertHistory.isEmpty)
        XCTAssertEqual(manager.detectedResetHistory.count, 1)
        XCTAssertEqual(ResetAlarmManager(defaults: defaults).detectedResetHistory, manager.detectedResetHistory)
        manager.clearAlertHistory()
        XCTAssertTrue(manager.detectedResetHistory.isEmpty)
        XCTAssertTrue(ResetAlarmManager(defaults: defaults).detectedResetHistory.isEmpty)
    }

    func testNoOpAndDeliveryOnlyChangesKeepInheritedSounds() {
        let name = "UsageAlertInheritedSoundTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ResetAlarmManager(defaults: defaults)
        let same = manager.preferences
        manager.preferences = same
        manager.preferences[.runaway].enabled = true
        manager.preferences[.anomaly].popup = true
        manager.alarmSound = .frog
        for kind in UsageAlertKind.allCases {
            XCTAssertEqual(manager.preferences[kind].sound, .frog)
        }
    }

    func testHealthyIdentityPruningRetainsExhaustionAcrossRelaunch() {
        let name = "UsageAlertRetentionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        func window(_ id: String, remaining: Double, date: Date) -> QuotaWindow {
            .init(id: id, provider: "Claude", providerKey: "anthropic", label: "Quota",
                  remainingPercent: remaining, window: "5h",
                  occurredAt: ISO8601DateFormatter().string(from: date))
        }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        let spent = window("spent", remaining: 0, date: now).normalizedForExport()
        XCTAssertTrue(spent.skip, "exhausted export windows deliberately carry skip")
        model.refreshActualExhaustion(windows: [spent], now: now)
        let original = model.exportedAlerts(now: now).first
        XCTAssertNotNil(original)
        let later = now.addingTimeInterval(1)
        let healthy = (0..<1_030).map { window("healthy-\($0)", remaining: 80, date: later) }
        model.refreshActualExhaustion(windows: healthy, now: later)
        XCTAssertEqual(model.exportedAlerts(now: later).first, original)
        let relaunched = MonitorModel(defaults: defaults)
        relaunched.skipsSnapshotIOForTesting = true
        relaunched.alarmManager.preferences[.quotaExhaustion].enabled = true
        relaunched.alarmManager.onUsageDelivery = { _, _, _, _ in XCTFail("existing depletion cannot repeat") }
        relaunched.refreshActualExhaustion(windows: [window("spent", remaining: 0,
            date: now.addingTimeInterval(2))], now: now.addingTimeInterval(2))
        XCTAssertEqual(relaunched.exportedAlerts(now: later).first, original)
    }

    func testCategoryChoicesPersistAndDisabledCategoryDoesNotDeliver() {
        let name = "UsageAlertDeliveryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "burnRateAlertsEnabled")
        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(manager.preferences[.anomaly].enabled)
        XCTAssertTrue(manager.preferences[.runaway].enabled)
        manager.preferences[.anomaly] = UsageAlertOption(enabled: false)
        manager.preferences[.runaway] = UsageAlertOption(enabled: true, notification: false,
                                                        popup: true, sound: .silent)
        var deliveries: [UsageAlertKind] = []
        manager.onUsageDelivery = { kind, _, _, option in
            deliveries.append(kind)
            XCTAssertFalse(option.notification)
            XCTAssertTrue(option.popup)
            XCTAssertEqual(option.sound, .silent)
        }
        manager.deliverUsageAlert(kind: .anomaly, title: "Anomaly", body: "Usage changed.", identifier: "a")
        manager.deliverUsageAlert(kind: .runaway, title: "Runaway", body: "Usage changed.", identifier: "b")
        XCTAssertEqual(deliveries, [.runaway])
        let relaunched = ResetAlarmManager(defaults: defaults)
        XCTAssertFalse(relaunched.preferences[.anomaly].enabled)
        XCTAssertEqual(relaunched.preferences[.runaway].sound, .silent)
    }

    func testDepletionFiresOnceAndRecoveryRearmsEvenWithForecastDisabled() {
        let name = "UsageAlertExhaustionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "exhaustionAlertsEnabled")
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.alarmManager.preferences[.quotaExhaustion] = UsageAlertOption(enabled: true, sound: .silent)
        var count = 0
        model.alarmManager.onUsageDelivery = { kind, _, _, _ in
            XCTAssertEqual(kind, .quotaExhaustion)
            count += 1
        }
        let now = Date()
        func window(_ remaining: Double, at date: Date? = nil) -> QuotaWindow {
            QuotaWindow(id: "anthropic:5h", provider: "Claude", providerKey: "anthropic",
                        label: "5-hour window", remainingPercent: remaining, window: "5h",
                        occurredAt: ISO8601DateFormatter().string(from: date ?? now))
        }
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now)
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now)
        XCTAssertEqual(count, 1)
        let firstID = model.exportedAlerts(now: now).first { $0.kind == "quotaExhaustion" }?.id
        model.refreshExhaustionWarningsForTesting(windows: [], now: now)
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now)
        XCTAssertEqual(count, 1)
        model.refreshExhaustionWarningsForTesting(windows: [window(10, at: now.addingTimeInterval(1))], now: now.addingTimeInterval(1))
        model.refreshExhaustionWarningsForTesting(windows: [window(0, at: now.addingTimeInterval(2))], now: now.addingTimeInterval(2))
        XCTAssertEqual(count, 2)
        XCTAssertNotEqual(firstID, model.exportedAlerts(now: now).first { $0.kind == "quotaExhaustion" }?.id)
    }

    func testLegacySoundUpdatesUncustomizedCategoriesAndPreservesExplicitChoices() {
        let name = "UsageAlertLegacySoundTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let manager = ResetAlarmManager(defaults: defaults)
        manager.preferences[.anomaly].sound = .silent
        manager.alarmSound = .submarine
        XCTAssertEqual(manager.preferences[.runaway].sound, .submarine)
        XCTAssertEqual(manager.preferences[.quotaReset].sound, .submarine)
        XCTAssertEqual(manager.preferences[.anomaly].sound, .silent)
    }

    func testAnomalyExportKeepsOccurrenceIdentityUntilRecovery() {
        let name = "UsageAlertOccurrenceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        let now = Date()
        func anomaly(at date: Date) -> AnomalyDetector.Anomaly {
            .init(providerKey: "anthropic", windowId: "anthropic:5h", kind: .vsBaseline,
                  multiplier: 6, summary: "Usage exceeds average.", observedAt: date)
        }
        model.injectRunawayAnomaliesForTests([anomaly(at: now)])
        let first = model.exportedAlerts(now: now).first
        XCTAssertEqual(first?.kind, "anomaly")
        XCTAssertTrue(first?.id.hasPrefix(QuotaPublisher.producerInstanceId + "|") == true)
        model.injectRunawayAnomaliesForTests([anomaly(at: now.addingTimeInterval(60))])
        XCTAssertEqual(first?.id, model.exportedAlerts(now: now).first?.id)
        XCTAssertEqual(first, model.exportedAlerts(now: now).first)
        model.injectRunawayAnomaliesForTests([])
        model.injectRunawayAnomaliesForTests([anomaly(at: now.addingTimeInterval(120))])
        XCTAssertNotEqual(first?.id, model.exportedAlerts(now: now).first?.id)
    }

    func testRestartAndOlderRecoveryDoNotRepeatExhaustion() {
        let name = "UsageAlertRestartTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        func window(_ remaining: Double, at date: Date) -> QuotaWindow {
            QuotaWindow(id: "anthropic:5h", provider: "Claude", providerKey: "anthropic",
                        label: "5-hour window", remainingPercent: remaining, window: "5h",
                        occurredAt: ISO8601DateFormatter().string(from: date))
        }
        let first = MonitorModel(defaults: defaults)
        first.skipsSnapshotIOForTesting = true
        first.alarmManager.preferences[.quotaExhaustion] = UsageAlertOption(enabled: true)
        first.alarmManager.onUsageDelivery = { _, _, _, _ in }
        first.refreshActualExhaustion(windows: [window(0, at: now)], now: now)
        let firstID = first.exportedAlerts(now: now).first?.id
        XCTAssertNotNil(firstID)
        let relaunched = MonitorModel(defaults: defaults)
        relaunched.skipsSnapshotIOForTesting = true
        var deliveries = 0
        relaunched.alarmManager.onUsageDelivery = { _, _, _, _ in deliveries += 1 }
        relaunched.refreshActualExhaustion(windows: [window(10, at: now.addingTimeInterval(-1))], now: now)
        relaunched.refreshActualExhaustion(windows: [window(10, at: now)], now: now)
        relaunched.refreshActualExhaustion(windows: [window(0, at: now.addingTimeInterval(1))], now: now.addingTimeInterval(1))
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(firstID, relaunched.exportedAlerts(now: now).first?.id)
        relaunched.refreshActualExhaustion(windows: [window(10, at: now.addingTimeInterval(2))], now: now.addingTimeInterval(2))
        relaunched.refreshActualExhaustion(windows: [window(0, at: now.addingTimeInterval(3))], now: now.addingTimeInterval(3))
        XCTAssertEqual(deliveries, 1)
        XCTAssertNotEqual(firstID, relaunched.exportedAlerts(now: now).first?.id)
    }

    func testAnomalyOccurrenceSurvivesRestart() {
        let name = "UsageAlertAnomalyRestartTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        func anomaly(at date: Date) -> AnomalyDetector.Anomaly {
            .init(providerKey: "anthropic", windowId: "anthropic:5h", kind: .vsPeak,
                  multiplier: 6, summary: "Usage exceeds peak.", observedAt: date)
        }
        let first = MonitorModel(defaults: defaults)
        first.skipsSnapshotIOForTesting = true
        first.injectRunawayAnomaliesForTests([anomaly(at: now)])
        let id = first.exportedAlerts(now: now).first?.id
        let relaunched = MonitorModel(defaults: defaults)
        relaunched.skipsSnapshotIOForTesting = true
        relaunched.injectRunawayAnomaliesForTests([anomaly(at: now.addingTimeInterval(60))])
        XCTAssertEqual(id, relaunched.exportedAlerts(now: now).first?.id)
        XCTAssertEqual(first.exportedAlerts(now: now), relaunched.exportedAlerts(now: now))
    }

    func testLongWindowIdentityProducesBoundedStableExportIDAndImmutablePayload() {
        let name = "UsageAlertLongIDTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        let now = Date()
        let windowID = String(repeating: "long-window-", count: 60)
        model.injectRunawayAnomaliesForTests([
            .init(providerKey: "anthropic", windowId: windowID, kind: .vsPeak,
                  multiplier: 6, summary: "Initial peak.", observedAt: now)
        ])
        let initial = model.exportedAlerts(now: now).first
        XCTAssertNotNil(initial)
        XCTAssertLessThanOrEqual(initial?.id.count ?? 1_000, 200)
        model.injectRunawayAnomaliesForTests([
            .init(providerKey: "anthropic", windowId: windowID, kind: .vsPeak,
                  multiplier: 9, summary: "A higher peak.", observedAt: now.addingTimeInterval(60))
        ])
        XCTAssertEqual(initial, model.exportedAlerts(now: now).first)
    }
}
