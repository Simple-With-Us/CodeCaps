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
            .allPlatforms,
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
        XCTAssertFalse(ConsolePage.allPlatforms.isSettings)
        XCTAssertFalse(ConsolePage.platform("anthropic").isSettings)
        XCTAssertTrue(ConsolePage.settingsMenuBar.isSettings)
        XCTAssertTrue(ConsolePage.settingsAppearance.isSettings)
        XCTAssertTrue(ConsolePage.settingsAbout.isSettings)
    }
}
