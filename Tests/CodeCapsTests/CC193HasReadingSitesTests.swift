import XCTest
@testable import CodeCaps
import QuotaCore

/// CC-193: every named surface uses `QuotaWindow.hasReading` instead of
/// `remainingPercent != nil` (or `remainingUnknown`) when deciding whether a
/// window carries a quota reading.
@MainActor
final class CC193HasReadingSitesTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let iso = ISO8601DateFormatter()

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func absoluteCreditsWindow(id: String = "credits") -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: "Grok Bot",
            providerKey: "grok-bot",
            label: "Grok Bot credits",
            absoluteRemaining: 6_099,
            absoluteLimit: 40_000,
            quotaUnit: "credits",
            remainingUnknown: true,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "local-test"
        )
    }

    private func snapshotRow(_ window: QuotaWindow) -> DisplaySection {
        let snap = QuotaWindowSnapshot(window: window, now: now)
        return DisplaySection(
            id: "grok-bot",
            providerKey: "grok-bot",
            title: "Grok Bot",
            platformTitle: "Grok Bot",
            section: QuotaPlatformSection(
                providerKey: "grok-bot",
                providerLabel: "Grok Bot",
                via: nil,
                expected: true,
                windows: [snap]
            ),
            poolKey: nil,
            remainingPercent: nil,
            resetAt: nil,
            maskedWindowIds: []
        )
    }

    // MARK: - MonitorModel.freshWindows

    func testFreshWindowsIncludesAbsoluteOnlyReading() {
        let suite = "cc193." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        let window = absoluteCreditsWindow()
        let response = QuotaResponse(generatedAt: iso.string(from: now), windows: [window])
        model.injectForTests(sections: response.platformSections(now: now), now: now)
        XCTAssertTrue(model.freshWindows.contains { $0.window.id == "credits" },
                      "freshWindows must treat absolute balances as readable")
    }

    func testMonitorModelFreshWindowsFilterUsesHasReading() throws {
        let source = try readSource("Sources/CodeCaps/MonitorModel.swift")
        guard let range = source.range(of: "var freshWindows:") else {
            return XCTFail("freshWindows not found")
        }
        let body = source[range.lowerBound...].prefix(600)
        XCTAssertTrue(body.contains("$0.window.hasReading"))
        XCTAssertFalse(body.contains("remainingPercent != nil"))
    }

    // MARK: - Pip HUD

    func testPipHUDCurrentWindowsAcceptsAbsoluteOnlyReading() {
        let row = snapshotRow(absoluteCreditsWindow())
        let windows = PipWidgetController.currentWindows(for: row, now: now)
        XCTAssertEqual(windows.map(\.window.id), ["credits"])
    }

    func testPipWidgetCurrentWindowsFilterUsesHasReading() throws {
        let source = try readSource("Sources/CodeCaps/PipWidget.swift")
        XCTAssertTrue(source.contains("!$0.isAwaitingRefresh && $0.window.hasReading"))
        XCTAssertTrue(source.contains("$0.remainingPercent != nil || $0.isFresh"))
        XCTAssertFalse(source.contains("&& !$0.window.remainingUnknown\n                && !disabledSources.contains"),
                       "PiP must not use remainingUnknown as the reading gate")
    }

    // MARK: - Pip low-quota scan

    func testPipLowQuotaScanUsesHasReadingNotRemainingUnknown() throws {
        let source = try readSource("Sources/CodeCaps/PipLowQuota.swift")
        XCTAssertTrue(source.contains("$0.isFresh && $0.window.hasReading"))
        XCTAssertFalse(source.contains("!$0.window.remainingUnknown\n                    && $0.remainingPercent != nil"),
                       "low-quota scan must not pair remainingUnknown with a percent check")
    }

    func testPipLowQuotaEvaluateObservesAbsoluteOnlyFreshWindow() {
        var session = PipLowQuotaSession()
        let row = snapshotRow(absoluteCreditsWindow())
        XCTAssertFalse(PipLowQuota.evaluate(rows: [row], thresholdPercent: 15, enabled: true,
                                              session: &session))
        XCTAssertEqual(session.observedWindowsByRow["grok-bot"]?.keys.sorted(), ["credits"])
    }

    // MARK: - GlanceViews (source pin)

    func testGlanceDrawableWindowsUsesHasReading() throws {
        let source = try readSource("Sources/CodeCaps/GlanceViews.swift")
        XCTAssertTrue(source.contains("windows.filter { $0.window.hasReading }.map(glanceMeterKey)"))
        XCTAssertTrue(source.contains("guard !snapshot.window.hasReading else { return true }"))
    }

    // MARK: - QuotaPublisher

    func testPublisherEmitsEventForAbsoluteOnlyReading() throws {
        let publisher = QuotaPublisher()
        let window = absoluteCreditsWindow()
        let payload = try publisher.buildUsageMonitorV2Payload(
            windows: [window],
            occurredAtIso: iso.string(from: now),
            machineName: "test"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1, "absolute-only windows must publish")
    }

    func testMakeUsageMonitorV2PayloadGuardsOnHasReading() throws {
        let source = try readSource("Sources/QuotaCore/QuotaPublisher.swift")
        XCTAssertTrue(source.contains("guard window.hasReading || window.planMetadata != nil else { return nil }"))
    }

    // MARK: - LocalQuotaReader

    func testLocalQuotaReaderGrokIssueRequiresNoHasReadingWindow() throws {
        let source = try readSource("Sources/QuotaCore/LocalQuotaReader.swift")
        XCTAssertTrue(source.contains("windows.contains(where: \\.hasReading) ? nil : \"Grok returned no readable quota percentage.\""))
    }

    // MARK: - CursorQuotaReader

    func testCursorQuotaReaderIssueRequiresNoHasReadingWindow() throws {
        let source = try readSource("Sources/QuotaCore/CursorQuotaReader.swift")
        XCTAssertTrue(source.contains("windows.allSatisfy { !$0.hasReading }"))
    }
}
