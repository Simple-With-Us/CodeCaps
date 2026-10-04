import XCTest
@testable import CodeCaps
@testable import QuotaCore

final class ConsoleNavigationTests: XCTestCase {
    func testConsoleMinMetrics() {
        XCTAssertEqual(Metrics.consoleMin.width, 880)
        XCTAssertEqual(Metrics.consoleMin.height, 600)
    }

    func testConsolePageSerialization() {
        let pages: [ConsolePage] = [
            .platform("anthropic"),
            .settingsMenuBar,
            .settingsPlatforms,
            .settingsLogoStyle,
            .settingsSourcesFleet,
            .settingsNotifications,
            .settingsAppearance,
            .settingsAbout
        ]

        for page in pages {
            let key = page.storageKey
            let restored = ConsolePage.fromStorageKey(key)
            XCTAssertEqual(restored, page, "ConsolePage \(page) should round-trip through storageKey")
        }
    }

    func testConsolePageIsSettings() {
        XCTAssertFalse(ConsolePage.platform("anthropic").isSettings)
        XCTAssertTrue(ConsolePage.settingsMenuBar.isSettings)
        XCTAssertTrue(ConsolePage.settingsAppearance.isSettings)
        XCTAssertTrue(ConsolePage.settingsAbout.isSettings)
    }

    func testQuotaViewLayoutCases() {
        XCTAssertEqual(QuotaViewLayout.allCases.count, 2)
        XCTAssertEqual(QuotaViewLayout.summary.title, "Compact")
        XCTAssertEqual(QuotaViewLayout.detailed.title, "Detailed")
    }
}

@MainActor
final class ConsoleSelectionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "ConsoleSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func row(_ key: String) -> DisplaySection {
        DisplaySection.rows(for: QuotaPlatformSection(providerKey: key, providerLabel: key,
                                                       via: nil, expected: true, windows: []), now: Date())[0]
    }

    func testLegacyAggregateSelectionWaitsForFirstPlatform() {
        let defaults = defaults()
        defaults.set("allPlatforms", forKey: "consoleLastPage")
        let state = ConsoleState(defaults: defaults)
        state.reconcile(available: [])
        XCTAssertEqual(state.page, .settingsSourcesFleet)
        state.reconcile(available: [row("anthropic"), row("openai")])
        XCTAssertEqual(state.page, .platform("anthropic"))
    }

    func testVanishedSavedPlatformFallsBackToFirstAvailable() {
        let defaults = defaults()
        defaults.set("platform:vanished", forKey: "consoleLastPage")
        let state = ConsoleState(defaults: defaults)
        state.reconcile(available: [])
        state.reconcile(available: [row("openai")])
        XCTAssertEqual(state.page, .platform("openai"))
    }

    func testExplicitSettingsSelectionSurvivesLaterRead() {
        let defaults = defaults()
        defaults.set("platform:anthropic", forKey: "consoleLastPage")
        let state = ConsoleState(defaults: defaults)
        state.reconcile(available: [row("anthropic")])
        state.page = .settingsNotifications
        state.reconcile(available: [row("openai")])
        XCTAssertEqual(state.page, .settingsNotifications)
        XCTAssertEqual(state.lastSettingsPage, .settingsNotifications)
    }

    func testAlertRouteSelectsMatchingPoolWindowAndTime() {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: true,
                                                                 fleet: false, localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ConsoleState(defaults: defaults)
        let at = GlanceFixtures.now.addingTimeInterval(-600)
        state.select(providerKey: "google-antigravity", windowId: "antigravity:gemini:weekly",
                     at: at, in: model.displaySections)
        XCTAssertEqual(state.page, .platform("google-antigravity:gemini"))
        XCTAssertEqual(state.selectedWindowId, "antigravity:gemini:weekly")
        XCTAssertEqual(state.selectedTimestamp, at)
    }

    func testUnavailableAlertDoesNotShowUnrelatedGraph() {
        let state = ConsoleState(defaults: defaults())
        state.select(providerKey: "missing", windowId: "unknown", at: Date(), in: [row("anthropic")])
        XCTAssertEqual(state.page, .settingsSourcesFleet)
        XCTAssertEqual(state.unavailableAlert?.providerKey, "missing")
    }

    func testAlertWaitsThroughPlaceholderUntilMatchingPoolWindowArrives() {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: true,
                                                                 fleet: false, localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ConsoleState(defaults: defaults)
        let at = GlanceFixtures.now.addingTimeInterval(-600)
        state.select(providerKey: "google-antigravity", windowId: "antigravity:gemini:weekly",
                     at: at, in: [row("google-antigravity")], readCompleted: false)
        XCTAssertEqual(state.page, .settingsSourcesFleet)
        XCTAssertNil(state.unavailableAlert)
        state.reconcile(available: model.displaySections, readCompleted: true)
        XCTAssertEqual(state.page, .platform("google-antigravity:gemini"))
        XCTAssertEqual(state.selectedTimestamp, at)
    }

    func testManualNavigationCancelsPendingAlert() {
        let state = ConsoleState(defaults: defaults())
        state.select(providerKey: "anthropic", windowId: "five-hour", at: Date(),
                     in: [], readCompleted: false)
        state.clearHistoryFocus()
        state.page = .settingsNotifications
        state.reconcile(available: [row("anthropic")], readCompleted: true)
        XCTAssertEqual(state.page, .settingsNotifications)
        XCTAssertNil(state.unavailableAlert)
    }

    func testNotificationRouteRejectsInvalidIdentityAndTimestamp() {
        XCTAssertNil(AlertNavigation(userInfo: ["windowId": "five-hour"]))
        let route = AlertNavigation(providerKey: "anthropic", windowId: "five-hour", timestamp: Date())
        XCTAssertEqual(AlertNavigation(userInfo: route.userInfo)?.windowId, "five-hour")
        let invalid = AlertNavigation(userInfo: ["providerKey": "anthropic", "observedAt": Double.infinity])
        XCTAssertNil(invalid?.timestamp)
    }

    func testNormalizedDisplayWindowRetainsLocalHistoryProvenance() throws {
        let model = MonitorModel(defaults: defaults())
        let now = Date()
        let local = QuotaWindow(id: "local-claude", provider: "Claude",
                                label: "5-hour window", remainingPercent: 70,
                                occurredAt: ISO8601DateFormatter().string(from: now),
                                accountKey: "local-account")
        model.injectLocalHistorySourceForTests([local])
        let response = QuotaResponse(generatedAt: "", windows: [local])
        let section = try XCTUnwrap(response.platformSections(now: now).first { $0.providerKey == "anthropic" })
        let row = try XCTUnwrap(DisplaySection.rows(for: section, now: now).first)
        XCTAssertNotEqual(row.section.windows.first?.window, local)
        XCTAssertTrue(model.hasLocalHistorySource(for: row))
        var otherAccount = local
        otherAccount.accountKey = "other-account"
        model.injectLocalHistorySourceForTests([otherAccount])
        XCTAssertFalse(model.hasLocalHistorySource(for: row))
    }

    func testPooledAntigravityDisplayRetainsLocalHistoryProvenance() throws {
        let model = MonitorModel(defaults: defaults())
        let now = Date()
        let local = QuotaWindow(id: "antigravity:gemini:5h", provider: "Antigravity",
                                providerKey: "google-antigravity", label: "Gemini Models · 5-hour",
                                remainingPercent: 70, window: "5h",
                                occurredAt: ISO8601DateFormatter().string(from: now),
                                accountKey: "local-account")
        model.injectLocalHistorySourceForTests([local])
        let response = QuotaResponse(generatedAt: "", windows: [local])
        let section = try XCTUnwrap(response.platformSections(now: now).first { $0.providerKey == "google-antigravity" })
        let row = try XCTUnwrap(DisplaySection.rows(for: section, now: now).first { $0.id == "google-antigravity:gemini" })
        XCTAssertTrue(model.hasLocalHistorySource(for: row))
        var remote = local
        remote.producerInstanceId = "other-machine"
        model.injectLocalHistorySourceForTests([remote])
        XCTAssertFalse(model.hasLocalHistorySource(for: row))
    }

    func testSameWindowIdFromAnotherProducerCannotShowLocalHistory() {
        let model = MonitorModel(defaults: defaults())
        let local = QuotaWindow(id: "shared-id", provider: "Claude", providerKey: "anthropic",
                                label: "5-hour window", remainingPercent: 70,
                                occurredAt: ISO8601DateFormatter().string(from: Date()))
        var remote = local
        remote.producerInstanceId = "other-machine"
        model.injectLocalHistorySourceForTests([local])
        let localSection = QuotaPlatformSection(providerKey: "anthropic", providerLabel: "Claude",
                                                via: nil, expected: true,
                                                windows: [QuotaWindowSnapshot(window: local)])
        let remoteSection = QuotaPlatformSection(providerKey: "anthropic", providerLabel: "Claude",
                                                 via: nil, expected: true,
                                                 windows: [QuotaWindowSnapshot(window: remote)])
        XCTAssertTrue(model.hasLocalHistorySource(for: DisplaySection.rows(for: localSection, now: Date())[0]))
        XCTAssertFalse(model.hasLocalHistorySource(for: DisplaySection.rows(for: remoteSection, now: Date())[0]))
    }
}
