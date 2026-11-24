import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
final class ProviderVisibilityTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "com.jays.codecaps.visibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func window(provider: String, providerKey: String) -> QuotaWindow {
        QuotaWindow(id: "local-mac:\(providerKey):5h", provider: provider, providerKey: providerKey,
                    label: "5h", remainingPercent: 50,
                    occurredAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30)),
                    source: provider)
    }

    @discardableResult
    private func model(_ settings: UserDefaults,
                       windows: [QuotaWindow]) async -> MonitorModel {
        let model = MonitorModel(defaults: settings, burnRateHistoryURL: URL(fileURLWithPath: "/dev/null"))
        model.skipsSnapshotIOForTesting = true
        model.localResultForTesting = LocalQuotaResult(windows: windows)
        model.serverFetchForTesting = { QuotaResponse(generatedAt: "test") }
        model.refresh()
        await model.refreshTaskForTesting?.value
        return model
    }

    func testPlatformsAreVisibleByDefault() async {
        let model = await model(defaults(), windows: [
            window(provider: "Claude", providerKey: "anthropic"),
            window(provider: "Codex", providerKey: "openai")])
        XCTAssertTrue(model.isProviderVisible("anthropic"))
        XCTAssertTrue(model.isProviderVisible("openai"))
        XCTAssertEqual(model.displaySections.map(\.providerKey).filter { $0 == "anthropic" }.count, 1)
        XCTAssertTrue(model.freshWindows.contains { $0.window.canonicalProviderKey == "anthropic" })
    }

    func testHidingAPlatformRemovesItFromDisplaySurfaces() async {
        let settings = defaults()
        let model = await model(settings, windows: [
            window(provider: "Claude", providerKey: "anthropic"),
            window(provider: "Codex", providerKey: "openai")])
        model.setProviderVisible(false, providerKey: "anthropic")
        XCTAssertFalse(model.isProviderVisible("anthropic"))
        XCTAssertTrue(model.isProviderVisible("openai"))
        XCTAssertFalse(model.displaySections.contains { $0.providerKey == "anthropic" },
                       "a hidden platform leaves the dashboard rows")
        XCTAssertTrue(model.displaySections.contains { $0.providerKey == "openai" })
        XCTAssertFalse(model.freshWindows.contains { $0.window.canonicalProviderKey == "anthropic" },
                       "a hidden platform cannot be picked for the menu bar")
        XCTAssertTrue(model.freshWindows.contains { $0.window.canonicalProviderKey == "openai" })
        // The platform is still observed:  its reading stays in the response.
        XCTAssertTrue(model.response.windows.contains { $0.canonicalProviderKey == "anthropic" })
    }

    func testVisibilityPreferencePersistsAcrossRestart() async {
        let settings = defaults()
        let windows = [window(provider: "Claude", providerKey: "anthropic"),
                       window(provider: "Codex", providerKey: "openai")]
        let first = await model(settings, windows: windows)
        first.setProviderVisible(false, providerKey: "anthropic")

        let restored = await model(settings, windows: windows)
        XCTAssertFalse(restored.isProviderVisible("anthropic"))
        XCTAssertFalse(restored.displaySections.contains { $0.providerKey == "anthropic" })
        XCTAssertTrue(restored.isProviderVisible("openai"))
    }

    func testShowingAHiddenPlatformRestoresItsRows() async {
        let settings = defaults()
        let windows = [window(provider: "Claude", providerKey: "anthropic")]
        let model = await model(settings, windows: windows)
        model.setProviderVisible(false, providerKey: "anthropic")
        XCTAssertTrue(model.displaySections.isEmpty)
        model.setProviderVisible(true, providerKey: "anthropic")
        XCTAssertTrue(model.isProviderVisible("anthropic"))
        XCTAssertEqual(model.displaySections.map(\.providerKey), ["anthropic"])
        XCTAssertEqual(model.freshWindows.count, 1)
    }

    func testCaseAndWhitespaceAreCanonicalized() async {
        let model = await model(defaults(),
                                windows: [window(provider: "Claude", providerKey: "anthropic")])
        model.setProviderVisible(false, providerKey: " Anthropic ")
        XCTAssertFalse(model.isProviderVisible("anthropic"))
        XCTAssertFalse(model.displaySections.contains { $0.providerKey == "anthropic" })
    }

    /// Kody, PR #549:  values stored before normalization (or edited by hand)
    /// must not resurrect a hidden platform after a restart.
    func testStoredNonCanonicalKeysNormalizeOnLoad() async {
        let settings = defaults()
        settings.set([" Anthropic "], forKey: "hiddenProviderKeys")
        let model = await model(settings,
                                windows: [window(provider: "Claude", providerKey: "anthropic")])
        XCTAssertFalse(model.isProviderVisible("anthropic"))
        XCTAssertFalse(model.displaySections.contains { $0.providerKey == "anthropic" })
    }

    /// Seer, PR #549:  hiding is display-only.  A hidden platform keeps its
    /// reset-alarm observations, so its bell still rings.
    func testHiddenPlatformKeepsResetAlarmObservations() async {
        let settings = defaults()
        let iso = ISO8601DateFormatter()
        var claude = window(provider: "Claude", providerKey: "anthropic")
        claude.resetAt = iso.string(from: Date().addingTimeInterval(3600))
        let model = await model(settings, windows: [claude])
        let before = model.resetAlarmObservationsForCurrentReadings()
        XCTAssertEqual(before.filter { $0.providerId == "anthropic" }.count, 1)
        model.setProviderVisible(false, providerKey: "anthropic")
        XCTAssertTrue(model.displaySections.isEmpty)
        let after = model.resetAlarmObservationsForCurrentReadings()
        XCTAssertEqual(after.filter { $0.providerId == "anthropic" }.count, 1,
                       "a hidden platform keeps its reset alarm")
    }
}
