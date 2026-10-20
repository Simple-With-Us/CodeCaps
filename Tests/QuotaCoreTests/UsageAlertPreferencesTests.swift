import XCTest
@testable import QuotaCore

final class UsageAlertPreferencesTests: XCTestCase {
    func testMigrationPreservesSilentAndExistingOptIns() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = UsageAlertPreferences.load(from: defaults, key: "alerts",
            resetEnabled: true, resetSound: .silent, runawayEnabled: false)
        XCTAssertTrue(preferences[.vendorReset].enabled)
        XCTAssertTrue(preferences[.quotaReset].enabled)
        XCTAssertFalse(preferences[.runaway].enabled)
        XCTAssertFalse(preferences[.anomaly].enabled)
        XCTAssertFalse(preferences[.quotaExhaustion].enabled)
        XCTAssertEqual(preferences[.quotaReset].sound, .silent)
    }

    func testEachCategoryPersistsIndependentlyOfLegacySettings() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = UsageAlertPreferences()
        preferences[.anomaly] = .init(enabled: true, notification: false, popup: true, sound: .glass)
        preferences[.runaway] = .init(enabled: true, sound: .silent)
        preferences.save(to: defaults, key: "alerts")
        let restored = UsageAlertPreferences.load(from: defaults, key: "alerts",
            resetEnabled: true, resetSound: .frog, runawayEnabled: false)
        XCTAssertEqual(restored, preferences)
        XCTAssertFalse(restored[.anomaly].notification)
        XCTAssertTrue(restored[.anomaly].popup)
        XCTAssertEqual(restored[.runaway].sound, .silent)
        XCTAssertFalse(restored[.quotaReset].enabled)
    }

    func testCorruptPreferencesFallBackToLegacyChoices() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: "alerts")
        let preferences = UsageAlertPreferences.load(from: defaults, key: "alerts",
            resetEnabled: false, resetSound: .tink, runawayEnabled: true)
        XCTAssertTrue(preferences[.anomaly].enabled)
        XCTAssertTrue(preferences[.runaway].enabled)
        XCTAssertFalse(preferences[.vendorReset].enabled)
    }
}
