import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
final class MenuBarPresetTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.jays.codecaps.menu-presets." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testMostUrgentFiveHourIgnoresStaleMaskedAndSupplementaryWindows() throws {
        let now = Date()
        let windows = [
            window("claude-short", provider: "anthropic", token: "5h", remaining: 20, now: now),
            window("claude-week", provider: "anthropic", token: "weekly", remaining: 30, now: now),
            window("stale-short", provider: "openai", token: "5h", remaining: 1,
                   now: now.addingTimeInterval(-3_600)),
            window("four-hour", provider: "cursor", token: "4h", remaining: 1, now: now),
            window("unclassified-near-reset", provider: "xai", token: nil, remaining: 0, label: "Usage quota", resetAfter: 3_600, now: now),
            window("minimax-video", provider: "minimax", token: "1d", remaining: 0,
                   model: "video", now: now),
            window("minimax-short", provider: "minimax", token: "5h", remaining: 25,
                   model: "general", now: now),
            window("gemini-short", provider: "google-antigravity", token: "5h", remaining: 1,
                   model: "gemini-pro", now: now),
            window("gemini-week", provider: "google-antigravity", token: "weekly", remaining: 0,
                   model: "gemini-pro", now: now),
        ]
        let model = makeModel(windows, selection: "most_urgent_5h", now: now)

        let selected = try XCTUnwrap(model.menuBarTargetSnapshot)
        XCTAssertEqual(selected.window.canonicalProviderKey, "anthropic")
        XCTAssertEqual(selected.remainingPercent, 20)
    }

    func testMostUrgentWeeklyUsesWeeklyCadenceAndFreshWindowsOnly() throws {
        let now = Date()
        let windows = [
            window("claude-week", provider: "anthropic", token: "168h", remaining: 30, now: now),
            window("codex-week", provider: "openai", token: "1w", remaining: 15, now: now),
            window("stale-week", provider: "xai", token: "weekly", remaining: 1,
                   now: now.addingTimeInterval(-3_600)),
            window("monthly", provider: "minimax", token: "billing_cycle", remaining: 0,
                   model: "general", label: "Monthly plan", resetAfter: 3_600, now: now),
            window("near-reset-unclassified", provider: "cursor", token: nil, remaining: 0, label: "Usage quota", resetAfter: 3_600, now: now),
        ]
        let model = makeModel(windows, selection: "most_urgent_weekly", now: now)

        let selected = try XCTUnwrap(model.menuBarTargetSnapshot)
        XCTAssertEqual(selected.window.id, "codex-week")
        XCTAssertEqual(model.menuBarTitle, "15%")
    }

    func testSmartPairSelectsUrgentPairFromOneProviderRow() throws {
        let now = Date()
        let windows = [
            window("claude-short", provider: "anthropic", token: "5h", remaining: 40, now: now),
            window("claude-week", provider: "anthropic", token: "weekly", remaining: 80, now: now),
            window("claude-monthly", provider: "anthropic", token: "billing_cycle", remaining: 0,
                   label: "Monthly plan", resetAfter: 3_600, now: now),
            window("codex-short", provider: "openai", token: "5h", remaining: 20, now: now),
            window("codex-week", provider: "openai", token: "weekly", remaining: 60, now: now),
        ]
        let model = makeModel(windows, selection: "smart_pair", now: now)

        XCTAssertEqual(model.menuBarTargetSnapshots.map { $0.window.canonicalProviderKey }, ["openai", "openai"])
        XCTAssertEqual(model.menuBarTargetSnapshots.map(\.window.id), ["codex-short", "codex-week"])
        XCTAssertEqual(model.menuBarTitle, "20% / 60%")
    }

    func testSmartPairPreservesAntigravityPoolIdentity() throws {
        let now = Date()
        let windows = [
            window("gemini-short", provider: "google-antigravity", token: "5h", remaining: 40,
                   model: "gemini-pro", now: now),
            window("gemini-week", provider: "google-antigravity", token: "weekly", remaining: 60,
                   model: "gemini-pro", now: now),
            window("third-short", provider: "google-antigravity", token: "5h", remaining: 5,
                   model: "claude-sonnet", now: now),
            window("third-week", provider: "google-antigravity", token: "weekly", remaining: 45,
                   model: "claude-sonnet", now: now),
        ]
        let model = makeModel(windows, selection: "smart_pair", now: now)

        XCTAssertEqual(model.menuBarTargetSnapshots.map { AntigravityQuotaGroups.poolKey(for: $0.window) },
                       ["third-party", "third-party"])
        XCTAssertEqual(model.menuBarTitle, "5% / 45%")
    }

    func testSmartPairShowsOneValueForExhaustedWeeklyOrSingleWindow() throws {
        let now = Date()
        let exhausted = makeModel([
            window("claude-short", provider: "anthropic", token: "5h", remaining: 10, now: now),
            window("claude-week", provider: "anthropic", token: "weekly", remaining: 0, now: now),
        ], selection: "smart_pair", now: now)
        XCTAssertEqual(exhausted.menuBarTargetSnapshots.map(\.window.id), ["claude-week"])
        XCTAssertEqual(exhausted.menuBarTitle, "0%")

        let single = makeModel([
            window("codex-week", provider: "openai", token: "weekly", remaining: 35, now: now),
        ], selection: "smart_pair", now: now)
        XCTAssertEqual(single.menuBarTargetSnapshots.map(\.window.id), ["codex-week"])
        XCTAssertEqual(single.menuBarTitle, "35%")
    }

    func testPlatformPinWindowPinAndLegacyAutomaticChoicesRemainDistinct() throws {
        let now = Date()
        let windows = [
            window("claude-short", provider: "anthropic", token: "5h", remaining: 5, now: now),
            window("codex-short", provider: "openai", token: "5h", remaining: 1, now: now),
            window("minimax-short", provider: "minimax", token: "5h", remaining: 30,
                   model: "general", now: now),
        ]
        let model = makeModel(windows, selection: "platform:minimax", now: now)
        XCTAssertEqual(model.menuBarTargetSnapshot?.window.id, "minimax-short")

        model.menuBarQuotaSelection = "claude-short"
        XCTAssertEqual(model.menuBarTargetSnapshot?.window.id, "claude-short")

        model.menuBarQuotaSelection = "auto_lowest_active"
        XCTAssertEqual(model.menuBarTargetSnapshot?.window.id, "codex-short")
        model.menuBarQuotaSelection = "auto_lowest"
        XCTAssertEqual(model.menuBarTargetSnapshot?.window.id, "codex-short")

        model.menuBarQuotaSelection = "retired-window-id"
        XCTAssertTrue(model.availableMenuBarQuotas.contains { $0.id == "retired-window-id" })
        XCTAssertEqual(model.menuBarQuotaSelection, "retired-window-id")
        XCTAssertEqual(model.menuBarTargetSnapshot?.window.id, "codex-short",
                       "the existing unavailable-window fallback remains automatic")
    }

    func testPinToPlatformPairShowsBothQuotasForMultiWindowPlatform() throws {
        let now = Date()
        let windows = [
            window("minimax-short", provider: "minimax", token: "5h", remaining: 0,
                   model: "general", now: now),
            window("minimax-week", provider: "minimax", token: "weekly", remaining: 65,
                   model: "general", now: now),
            window("claude-short", provider: "anthropic", token: "5h", remaining: 10, now: now),
        ]
        let model = makeModel(windows, selection: "platform_pair:minimax", now: now)
        XCTAssertEqual(model.menuBarTargetSnapshots.count, 2)
        XCTAssertEqual(model.menuBarTargetSnapshots[0].window.id, "minimax-short")
        XCTAssertEqual(model.menuBarTargetSnapshots[1].window.id, "minimax-week")
        XCTAssertEqual(model.menuBarTitle, "0% / 65%")
        XCTAssertTrue(model.menuBarDetail.contains("MiniMax"))
        XCTAssertTrue(model.menuBarDetail.contains("0%"))
        XCTAssertTrue(model.menuBarDetail.contains("65%"))

        // Single quota platform pin still yields 1 quota (lowest)
        model.menuBarQuotaSelection = "platform:minimax"
        XCTAssertEqual(model.menuBarTargetSnapshots.count, 1)
        XCTAssertEqual(model.menuBarTargetSnapshots[0].window.id, "minimax-short")
        XCTAssertEqual(model.menuBarTitle, "0%")
    }

    func testMenuBarQuotaDescriptionProvidesClearExplanation() {
        let now = Date()
        let windows = [
            window("minimax-short", provider: "minimax", token: "5h", remaining: 0, model: "general", now: now),
            window("minimax-week", provider: "minimax", token: "weekly", remaining: 65, model: "general", now: now),
        ]
        let model = makeModel(windows, selection: "smart_pair", now: now)
        XCTAssertTrue(model.menuBarQuotaDescription(for: "smart_pair").contains("Automatically monitors the most urgent platform"))
        XCTAssertTrue(model.menuBarQuotaDescription(for: "platform_pair:minimax").contains("displays both its short and weekly quota percentages side by side"))
        XCTAssertTrue(model.menuBarQuotaDescription(for: "platform:minimax").contains("showing the lowest remaining percentage"))
        XCTAssertTrue(model.menuBarQuotaDescription(for: "auto_lowest_active").contains("above 0%"))
    }

    private func makeModel(_ windows: [QuotaWindow], selection: String, now: Date) -> MonitorModel {
        let model = MonitorModel(defaults: defaults)
        model.menuBarQuotaSelection = selection
        let response = QuotaResponse(generatedAt: ISO8601DateFormatter().string(from: now), windows: windows)
        model.injectForTests(sections: response.platformSections(now: now), now: now)
        return model
    }

    private func window(_ id: String, provider: String, token: String?, remaining: Double,
                        model: String? = nil, label: String? = nil,
                        resetAfter: TimeInterval = 86_400, now: Date) -> QuotaWindow {
        let canonicalLabel = label ?? token ?? "Quota"
        return QuotaWindow(id: id, provider: provider, providerKey: provider, modelId: model,
                           label: canonicalLabel, remainingPercent: remaining,
                           resetAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(resetAfter)),
                           window: token, occurredAt: ISO8601DateFormatter().string(from: now))
    }
}
