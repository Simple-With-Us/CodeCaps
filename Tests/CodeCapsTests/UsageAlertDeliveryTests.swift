import XCTest
import QuotaCore
@testable import CodeCaps

@MainActor
final class UsageAlertDeliveryTests: XCTestCase {
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
        func window(_ remaining: Double) -> QuotaWindow {
            QuotaWindow(id: "anthropic:5h", provider: "Claude", providerKey: "anthropic",
                        label: "5-hour window", remainingPercent: remaining, window: "5h",
                        occurredAt: ISO8601DateFormatter().string(from: now))
        }
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now)
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now)
        XCTAssertEqual(count, 1)
        let firstID = model.exportedAlerts(now: now).first { $0.kind == "quotaExhaustion" }?.id
        model.refreshExhaustionWarningsForTesting(windows: [], now: now)
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now)
        XCTAssertEqual(count, 1)
        model.refreshExhaustionWarningsForTesting(windows: [window(10)], now: now)
        model.refreshExhaustionWarningsForTesting(windows: [window(0)], now: now.addingTimeInterval(1))
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
        model.injectRunawayAnomaliesForTests([anomaly(at: now.addingTimeInterval(60))])
        XCTAssertEqual(first?.id, model.exportedAlerts(now: now).first?.id)
        model.injectRunawayAnomaliesForTests([])
        model.injectRunawayAnomaliesForTests([anomaly(at: now.addingTimeInterval(120))])
        XCTAssertNotEqual(first?.id, model.exportedAlerts(now: now).first?.id)
    }
}
