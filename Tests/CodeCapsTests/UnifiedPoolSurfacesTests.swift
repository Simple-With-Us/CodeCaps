import XCTest
@testable import CodeCaps
import QuotaCore

/// The unified subscription pool is read by more than the app's own rows.
///
/// The app publishes the pool's rows, so the widget and the exhaustion
/// alerts read the pre-unification list and contradict it:  a provider
/// another provider had just filled in read "stale" on the widget and in the
/// alerts while the app showed the live number.
@MainActor
final class UnifiedPoolSurfacesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "com.jays.codecaps.unifiedpool.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Two providers of one pool:  Grok's reading is the fresh one, so the
    /// Cursor row shows the pool's number and the pool's date.
    private func poolRead(now: Date) -> LocalQuotaResult {
        let iso = ISO8601DateFormatter()
        let cursor = QuotaWindow(
            id: "local-mac:cursor:plan",
            provider: "Cursor",
            providerKey: "cursor",
            providerLabel: "Cursor",
            sourceApp: "local-mac",
            label: "Included plan",
            remainingPercent: 40,
            resetAt: iso.string(from: now.addingTimeInterval(6 * 86_400)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "Cursor"
        )
        let grok = QuotaWindow(
            id: "local-mac:grok:subscription",
            provider: "Grok",
            providerKey: "grok",
            providerLabel: "Grok",
            sourceApp: "local-mac",
            label: "Subscription window",
            remainingPercent: 0,
            resetAt: iso.string(from: now.addingTimeInterval(6 * 86_400)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-10)),
            source: "Grok"
        )
        return LocalQuotaResult(windows: [cursor, grok])
    }

    /// The widget publishes the rows the app publishes.
    ///
    /// The widget read the pre-unification list, so the Cursor row showed the
    /// old 40% while the app showed the pool's 0%.
    func testTheWidgetPublishesTheUnifiedRows() async throws {
        let model = MonitorModel(defaults: defaults())
        model.skipsSnapshotIOForTesting = true
        let local = poolRead(now: Date())
        model.localReadForTesting = { local }
        var published: [[QuotaWindow]] = []
        model.widgetWriteForTesting = { published.append($0) }

        model.refresh()
        await model.refreshTaskForTesting?.value

        let appRow = model.response.windows.first { $0.canonicalProviderKey == "cursor" }
        XCTAssertEqual(appRow?.remainingPercent, 0, "the app's row shows the pool's reading")

        let widgetWindows = try XCTUnwrap(published.last)
        let widgetRow = widgetWindows.first { $0.canonicalProviderKey == "cursor" }
        XCTAssertEqual(widgetRow?.remainingPercent, 0,
                       "the widget publishes the pool's reading, not the pre-unification one")
    }

    /// The exhaustion alerts read the rows the app publishes.
    ///
    /// The alerts read the pre-unification list, so the Cursor row read 40%
    /// and no alert fired while the app showed the pool's 0%.
    func testTheExhaustionAlertsReadTheUnifiedRows() async throws {
        let model = MonitorModel(defaults: defaults())
        model.skipsSnapshotIOForTesting = true
        model.alarmManager.preferences[.quotaExhaustion] = UsageAlertOption(enabled: true, sound: .silent)
        let local = poolRead(now: Date())
        model.localReadForTesting = { local }
        var alerts: [String] = []
        model.alarmManager.onUsageDelivery = { kind, title, _, _ in
            guard kind == .quotaExhaustion else { return }
            alerts.append(title)
        }

        model.refresh()
        await model.refreshTaskForTesting?.value

        XCTAssertTrue(alerts.contains("Quota Exhausted: Grok"),
                      "the pool's own row is at its cap")
        XCTAssertTrue(alerts.contains("Quota Exhausted: Cursor"),
                      "the row the pool filled in is at its cap too")
    }

    /// The HUD resolves its rows once per render and hands the same list to
    /// every row helper.
    ///
    /// `orderedPipDisplaySections` walks every window of every provider, so
    /// asking for it again inside each row helper rebuilt the same list once
    /// per row, once per frame.
    func testThePipRowHelpersUseTheSectionsTheRenderResolved() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/CodeCaps/PipWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for helper in ["private func pipRow", "private func detailPanel", "private func anyRowSpiking"] {
            let start = try XCTUnwrap(source.range(of: helper), "the helper \(helper) is in the file")
            let rest = source[start.upperBound...]
            let end = try XCTUnwrap(rest.range(of: "\n    private "), "the helper \(helper) ends")
            let body = rest[rest.startIndex..<end.lowerBound]
            XCTAssertFalse(body.contains("orderedPipDisplaySections()"),
                           "\(helper) must use the sections the render resolved, not ask for them again")
        }
        XCTAssertTrue(source.contains("let peerRows = model.orderedPipDisplaySections()"),
                      "the render resolves the sections once")
    }
}
