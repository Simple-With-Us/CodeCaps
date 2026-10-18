import XCTest
import QuotaCore
@testable import CodeCaps

@MainActor
final class SharedGrokDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func reading(key: String = "grok", percent: Double = 42, age: TimeInterval = 0,
                         producer: String = "mac-a") -> QuotaWindow {
        QuotaWindow(id: "local-mac:\(key):subscription", provider: key, providerKey: key, providerLabel: key == "grok" ? "Grok" : key,
                    sourceApp: "local-mac", label: "1w window", remainingPercent: percent,
                    resetAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(86_400)), window: "1w",
                    occurredAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-age)),
                    source: "Grok", accountKey: "account-a", producerInstanceId: producer)
    }

    private func model(windows: [QuotaWindow], defaults: UserDefaults) -> MonitorModel {
        let model = MonitorModel(defaults: defaults, presentsPipWindows: false)
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows).platformSections(now: now), now: now)
        return model
    }

    func testFourLogoChoicesShareOneReadingAndDoNotMultiplyCountsOrAlarms() throws {
        let suite = "SharedGrokDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = model(windows: [reading(percent: 12)], defaults: defaults)
        XCTAssertEqual(model.displaySections.filter { $0.providerKey == "grok" }.map(\.id), ["grok"])
        model.sharedGrokLogoIDs = SharedGrokDisplay.ids
        let rows = model.displaySections.filter { $0.providerKey == "grok" }
        XCTAssertEqual(Set(rows.map(\.id)), SharedGrokDisplay.ids)
        for row in rows {
            XCTAssertEqual(row.section.windows, rows[0].section.windows)
            XCTAssertEqual(row.remainingPercent, 12)
            XCTAssertEqual(row.section.windows.first?.window.id, reading().id)
        }
        XCTAssertEqual(model.freshWindows.count, 1)
        XCTAssertEqual(model.menuBarIndividualWindowOptions.count, 1)
        XCTAssertEqual(model.reportingCount, 1)
        XCTAssertEqual(model.nearCapCount, 1)
        XCTAssertEqual(model.resetAlarmObservationsForCurrentReadings().count, 1)
        XCTAssertEqual(model.resetAlarmObservationsForCurrentReadings().first?.providerId, "grok")
    }

    func testSelectedLogosPersistAndMenuPinUsesSelectedBrand() throws {
        let suite = "SharedGrokDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = model(windows: [reading()], defaults: defaults)
        model.sharedGrokLogoIDs = ["xai", "cursor-grok"]
        model.menuBarQuotaSelection = "platform:cursor-grok"
        XCTAssertEqual(model.displayRow(for: reading())?.id, "cursor-grok")
        XCTAssertEqual(model.menuBarTargetSnapshot?.remainingPercent, 42)
        XCTAssertEqual(model.orderedPipDisplaySections().filter { $0.providerKey == "grok" }.map(\.id), ["xai", "cursor-grok"])
        let relaunched = MonitorModel(defaults: defaults, presentsPipWindows: false)
        XCTAssertEqual(relaunched.sharedGrokLogoIDs, ["xai", "cursor-grok"])
        model.sharedGrokLogoIDs = []
        XCTAssertFalse(model.displaySections.contains { $0.providerKey == "grok" })
        XCTAssertEqual(model.freshWindows.count, 1, "visibility must not create or destroy the source reading")
    }

    func testExistingMenuPinAndAliasAlarmSurviveUpgrade() throws {
        let suite = "SharedGrokDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("platform:xai", forKey: "menuBarQuotaSelection")
        defaults.set(false, forKey: "resetAlarmAll")
        defaults.set(["grok-bot", "anthropic"], forKey: "resetAlarmProviders")
        let model = model(windows: [reading()], defaults: defaults)
        XCTAssertEqual(model.sharedGrokLogoIDs, ["xai"])
        XCTAssertEqual(model.menuBarTargetSnapshot?.remainingPercent, 42)
        XCTAssertEqual(model.displayRow(for: reading())?.id, "xai")
        XCTAssertTrue(model.isAlarmEnabled(for: "xai"))
        XCTAssertTrue(model.isAlarmEnabled(for: "grok"))
        XCTAssertTrue(model.isAlarmEnabled(for: "anthropic"))
        XCTAssertEqual(Set(defaults.stringArray(forKey: "resetAlarmProviders") ?? []), ["grok", "anthropic"])
    }

    func testFreshRetiredAliasesCannotResurrectAStaleGrokReading() throws {
        let old = reading(age: 3600)
        let obsolete = reading(key: "grok-bot", percent: 99)
        let windows = SharedGrokDisplay.authoritativeWindows([old, obsolete])
        XCTAssertEqual(windows, [old])
        let rows = SharedGrokDisplay.rows(sections: QuotaResponse(generatedAt: "", windows: windows).platformSections(now: now), now: now)
        for row in rows where row.providerKey == "grok" {
            XCTAssertFalse(try XCTUnwrap(row.section.windows.first).isFresh)
            XCTAssertEqual(row.section.windows.first?.window.occurredAt, old.occurredAt)
        }
        XCTAssertTrue(SharedGrokDisplay.authoritativeWindows([obsolete]).isEmpty)
    }

    func testXAIAndGrokDeduplicatePerProducerWithoutMixingMachines() {
        let old = reading(key: "xai", percent: 20, age: 300)
        let current = reading(percent: 42)
        let other = reading(percent: 75, producer: "mac-b")
        let windows = SharedGrokDisplay.authoritativeWindows([old, current, other])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.remainingPercent), [42, 75])
        XCTAssertEqual(windows.map(\.producerInstanceId), ["mac-a", "mac-b"])
    }

    func testEquivalentWeeklyCadenceTokensDoNotMultiplyAllowance() {
        var old = reading(key: "xai", percent: 12, age: 60)
        old.window = "weekly"
        var current = reading(percent: 42)
        current.window = "1w"
        let windows = SharedGrokDisplay.authoritativeWindows([old, current])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.remainingPercent, 42)
    }

    func testCursorOwnPlanSurvivesButRetiredWeeklyLookupDoesNot() {
        var own = reading(key: "cursor", percent: 63)
        own.source = "Cursor"
        own.window = "billing-cycle"
        var retired = own
        retired.window = "weekly"
        let windows = SharedGrokDisplay.authoritativeWindows([reading(), own, retired, reading(key: "grok-bot")])
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.first { $0.canonicalProviderKey == "cursor" }?.remainingPercent, 63)
        XCTAssertEqual(windows.first { $0.canonicalProviderKey == "cursor" }?.window, "billing-cycle")
        XCTAssertFalse(ReaderStatus.all.contains { $0.providerKey == "grok-bot" })
    }
}
