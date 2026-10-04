import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Draws the screenshots the landing page and README embed, from invented
/// demo readings, so they show the current design instead of an old build.
///
/// Not part of CI: with `CODECAPS_DOCS_RENDER_DIR` unset the test skips.  Run
/// it, shrink the Console pictures to their published size, and copy the files
/// into `docs/screenshots/`:
///
///     CODECAPS_DOCS_RENDER_DIR=/some/dir swift test --filter DocsScreenshotTests
///     sips -Z 1280 /some/dir/console-*.png /some/dir/platform-*.png /some/dir/settings-*.png
@MainActor
final class DocsScreenshotTests: XCTestCase {
    private let consoleSize = CGSize(width: 1000, height: 700)

    private func write(_ png: Data?, _ name: String, to directory: URL) throws {
        guard let png else { throw XCTSkip("AppKit could not draw offscreen in this session") }
        try png.write(to: directory.appendingPathComponent(name))
    }

    private func glance(view: GlanceViewMode, dark: Bool) throws -> Data? {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: view, alarmsAll: true, fleet: true,
                                                                localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        let height = QuotaGlanceMetrics.popoverHeight(for: model)
        let popover = GlancePopover(model: model, openConsole: { _ in }, openSettings: {})
        return GlanceFixtures.png(of: popover, size: CGSize(width: Metrics.glanceWidth, height: height), dark: dark)
    }

    private func console(page: ConsolePage, dark: Bool, selectedAlert: Bool = false) -> Data? {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = temporary.appendingPathComponent("history.jsonl")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let now = GlanceFixtures.now
        let samples: [AnomalyDetector.Sample] = (0...12).flatMap { step in
            let at = now.addingTimeInterval(Double(step - 12) * 600)
            return [
                AnomalyDetector.Sample(providerKey: "anthropic", windowId: "claude-5h", observedAt: at,
                                       remainingPercent: Double(85 - step * 4)),
                AnomalyDetector.Sample(providerKey: "anthropic", windowId: "claude-7d", observedAt: at,
                                       remainingPercent: Double(98 - step))
            ]
        }
        try? AnomalyDetector.SampleHistory(url: historyURL).append(samples)
        let alert = RunawayAlertRecord(timestamp: now.addingTimeInterval(-3_600), providerKey: "anthropic",
                                       providerLabel: "Claude", windowId: "claude-5h",
                                       windowLabel: "5-hour window", multiplier: 5.3,
                                       comparison: "available-history average",
                                       summary: "Claude (5-hour window) is spending quota at 5.3× its measured average.",
                                       ratePercentPerHour: 24, comparisonRatePercentPerHour: 4.5,
                                       historyCoverageHours: 6)
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: true, fleet: false,
                                                                localReadersOn: true,
                                                                historyURL: historyURL,
                                                                alertHistory: selectedAlert ? [alert] : [])
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ConsoleState(defaults: defaults)
        state.page = page
        if selectedAlert {
            state.select(providerKey: "anthropic", windowId: "claude-5h", at: alert.timestamp,
                         in: model.displaySections)
        }
        return GlanceFixtures.png(of: ConsoleView(model: model, state: state), size: consoleSize, dark: dark)
    }

    func testRenderDocsScreenshots() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_DOCS_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_DOCS_RENDER_DIR to render the docs screenshots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CodeCapsVersion.display = "Version 1.0.0 (1)"

        try write(glance(view: .fromMac, dark: false), "glance-light.png", to: directory)
        try write(glance(view: .fromMac, dark: true), "glance-dark.png", to: directory)
        try write(glance(view: .fromFleet, dark: false), "glance-fleet.png", to: directory)
        try write(console(page: .platform("anthropic"), dark: false), "console-light.png", to: directory)
        try write(console(page: .platform("anthropic"), dark: true), "console-dark.png", to: directory)
        try write(console(page: .platform("anthropic"), dark: false, selectedAlert: true),
                  "platform-alert-history.png", to: directory)
        try write(console(page: .platform("google-antigravity:gemini"), dark: false),
                  "platform-antigravity.png", to: directory)
        try write(console(page: .settingsSourcesFleet, dark: false), "settings-sources-fleet.png", to: directory)
    }
}
