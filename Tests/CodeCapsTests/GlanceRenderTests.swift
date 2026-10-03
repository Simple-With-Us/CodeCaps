import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Renders the Glance popover to PNG so a person can look at it: both views of
/// the From Mac / From Fleet switch (two sources under From Fleet), All on and
/// All off with a mix of per-row bells, MiniMax expanded, Claude signed out,
/// the two Antigravity pool marks, Cursor's "1m" window and the fleet empty
/// state, in Light and Dark.
///
/// Evidence, not an assertion about pixels, and CI does not depend on it: with
/// `CODECAPS_GLANCE_RENDER_DIR` unset the test skips.  Nothing it writes is
/// committed.
///
///     CODECAPS_GLANCE_RENDER_DIR=/some/dir swift test --filter GlanceRenderTests
@MainActor
final class GlanceRenderTests: XCTestCase {
    private func render(_ name: String, view: GlanceViewMode, alarmsAll: Bool, fleet: Bool = true,
                        expanded: Set<String> = [], signedOut: Set<String> = [],
                        runawayAlert: Bool = false,
                        dark: Bool, into directory: URL) throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(
            view: view, alarmsAll: alarmsAll, fleet: fleet,
            extraWindows: expanded.contains("anthropic") ? [GlanceFixtures.claudeSonnetWindow] : [],
            signedOut: signedOut)
        defer { defaults.removePersistentDomain(forName: suite) }
        if runawayAlert {
            model.burnRateAlertsEnabled = true
            model.injectRunawayAnomaliesForTests([
                AnomalyDetector.Anomaly(providerKey: "anthropic", windowId: "claude-5h", kind: .vsPeak,
                                        multiplier: 6.4, summary: "Claude 5-hour usage is 6.4× its recent peak.")
            ])
        }
        // The popover budgets its height for collapsed rows; an open row's
        // extra lines scroll.  The render adds them so the PNG shows them.
        let expandedLines = model.displaySections.filter { expanded.contains($0.id) }
            .map { CGFloat(glanceExpandedLines(for: $0, now: model.now).count) * Metrics.glanceExpandedLineHeight + 4 }
            .reduce(0, +)
        let height = QuotaGlanceMetrics.popoverHeight(for: model) + (view == .fromMac ? expandedLines : 0)
        let popover = GlancePopover(model: model, openConsole: { _ in }, openSettings: {},
                                    initiallyExpanded: expanded)
        guard let png = GlanceFixtures.png(of: popover, size: CGSize(width: Metrics.glanceWidth, height: height),
                                           dark: dark) else {
            throw XCTSkip("AppKit could not draw offscreen in this session")
        }
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    func testRenderGlancePopoverGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_GLANCE_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_GLANCE_RENDER_DIR to render the Glance popover")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            try render("glance-frommac-all-on", view: .fromMac, alarmsAll: true, dark: dark, into: directory)
            try render("glance-frommac-all-off", view: .fromMac, alarmsAll: false, dark: dark, into: directory)
            try render("glance-frommac-runaway-alert", view: .fromMac, alarmsAll: true,
                       runawayAlert: true, dark: dark, into: directory)
            try render("glance-frommac-minimax-expanded", view: .fromMac, alarmsAll: true,
                       expanded: ["minimax", "anthropic"], dark: dark, into: directory)
            try render("glance-frommac-claude-signed-out", view: .fromMac, alarmsAll: false,
                       signedOut: ["anthropic"], dark: dark, into: directory)
            try render("glance-fromfleet-all-on", view: .fromFleet, alarmsAll: true, dark: dark, into: directory)
            try render("glance-fromfleet-all-off", view: .fromFleet, alarmsAll: false, dark: dark, into: directory)
            try render("glance-fromfleet-empty", view: .fromFleet, alarmsAll: true, fleet: false,
                       dark: dark, into: directory)
        }
    }
}
