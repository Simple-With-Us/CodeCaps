import XCTest
@testable import CodeCaps

/// The pull and sync endpoints default to empty strings, and both features
/// default to disabled, so a fresh install never posts to anyone else's
/// server until the owner configures one explicitly.
@MainActor
final class SettingsMigrationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.jays.agent-bar.tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testInvalidSavedReadTokenDoesNotChangeRemoteSettings() async {
        let model = MonitorModel(defaults: defaults)
        model.readTokenReadForTesting = { nil }
        var remoteWrites = 0
        model.settingsWriteForTesting = { _, _ in remoteWrites += 1 }
        do {
            try await model.saveConnection(local: false, server: true,
                                           endpoint: "https://quota.example.com/read", token: "")
            XCTFail("An unreadable saved token must reject the save")
        } catch {
            XCTAssertEqual(remoteWrites, 0)
            XCTAssertEqual(model.endpoint, "")
            XCTAssertFalse(model.serverEnabled)
        }
    }

    func testFreshInstallPostsNowhere() {
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.endpoint, "")
        XCTAssertEqual(model.syncEndpoint, "")
        XCTAssertNil(defaults.string(forKey: "endpoint"))
        XCTAssertNil(defaults.string(forKey: "syncEndpoint"))
    }

    /// With no UserDefaults keys ever set, both endpoints are empty strings
    /// and both the pull (server) and sync features start disabled.
    func testAFreshDomainHasEmptyEndpointsAndBothFeaturesDisabled() {
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.endpoint, "")
        XCTAssertEqual(model.syncEndpoint, "")
        XCTAssertFalse(model.serverEnabled)
        XCTAssertFalse(model.syncEnabled)
    }

    func testAStoredEndpointIsNeverClobbered() {
        defaults.set(true, forKey: "hasSavedToken")
        defaults.set(true, forKey: "hasSavedSyncToken")
        defaults.set("https://quota.example.com/api/quota-windows", forKey: "endpoint")
        defaults.set("https://quota.example.com/api/ingest/usage", forKey: "syncEndpoint")
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.endpoint, "https://quota.example.com/api/quota-windows")
        XCTAssertEqual(model.syncEndpoint, "https://quota.example.com/api/ingest/usage")
    }

    func testAnEmptyStoredEndpointStaysEmptyEvenWithASavedToken() {
        // The user cleared the field deliberately; a saved token must not undo it.
        defaults.set(true, forKey: "hasSavedToken")
        defaults.set("", forKey: "endpoint")
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.endpoint, "")
    }

    func testATokenlessUpgradeIsNotGivenAnEndpoint() {
        defaults.set(true, forKey: "serverEnabled")
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.endpoint, "")
        XCTAssertEqual(model.syncEndpoint, "")
    }

    /// A pinned quota must survive a refresh that cannot see its window, or the
    /// Picker draws an empty selection and the pin is lost.
    func testAnUnavailablePinnedQuotaKeepsItsRow() {
        defaults.set("some-retired-window-id", forKey: "menuBarQuotaSelection")
        let model = MonitorModel(defaults: defaults)
        let ids = model.availableMenuBarQuotas.map(\.id)
        XCTAssertTrue(ids.contains("some-retired-window-id"))
        XCTAssertEqual(ids.first, "most_urgent_5h")
        XCTAssertEqual(model.menuBarQuotaSelection, "some-retired-window-id")
    }

    func testFreshInstallDefaultsToSmartPairAndOffersPresets() {
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.menuBarQuotaSelection, "smart_pair")
        let ids = Set(model.availableMenuBarQuotas.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["most_urgent_5h", "most_urgent_weekly", "smart_pair",
                                          "auto_lowest_active", "auto_lowest"]))
        XCTAssertFalse(model.availableMenuBarQuotas.contains { $0.label == "Pinned quota unavailable" })
    }
}

final class ConsolePageStorageTests: XCTestCase {
    func testEveryPageRoundTripsThroughItsStorageKey() {
        let pages: [ConsolePage] = [
            .platform("anthropic"), .platform("google-antigravity:gemini"),
            .platform("a:b"), .settingsMenuBar, .settingsPlatforms, .settingsSourcesFleet,
            .settingsAppearance, .settingsAbout,
        ]
        for page in pages {
            XCTAssertEqual(ConsolePage.fromStorageKey(page.storageKey), page, "\(page.storageKey)")
        }
    }

    func testAnUnknownKeyIsRejectedRatherThanGuessed() {
        XCTAssertNil(ConsolePage.fromStorageKey(""))
        XCTAssertNil(ConsolePage.fromStorageKey("allPlatforms"))
        XCTAssertNil(ConsolePage.fromStorageKey("settingsNothing"))
        XCTAssertEqual(ConsolePage.fromStorageKey("platform:"), .platform(""))
    }

    func testOnlySettingsPagesReportThemselvesAsSettings() {
        XCTAssertFalse(ConsolePage.platform("anthropic").isSettings)
        for page in ConsolePage.settingsPages { XCTAssertTrue(page.isSettings) }
    }
}
