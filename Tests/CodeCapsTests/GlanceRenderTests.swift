import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Renders the Glance popover to PNG so a person can look at it: both views of
/// the This Mac / Fleet Reported switch, All on and All off with a mix of
/// per-row bells, the two Antigravity pool marks, Cursor's "1m" window, the
/// fleet empty state, in Light and Dark.
///
/// Evidence, not an assertion about pixels, and CI does not depend on it: with
/// `CODECAPS_GLANCE_RENDER_DIR` unset the test skips.  Nothing it writes is
/// committed.
///
///     CODECAPS_GLANCE_RENDER_DIR=/some/dir swift test --filter GlanceRenderTests
@MainActor
final class GlanceRenderTests: XCTestCase {
    private func render(_ name: String, view: GlanceViewMode, alarmsAll: Bool, fleet: Bool = true,
                        expanded: Set<String> = [], dark: Bool, into directory: URL) throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(
            view: view, alarmsAll: alarmsAll, fleet: fleet,
            extraWindows: expanded.isEmpty ? [] : [GlanceFixtures.claudeSonnetWindow])
        defer { defaults.removePersistentDomain(forName: suite) }
        let height = QuotaGlanceMetrics.popoverHeight(for: model)
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
            try render("glance-thismac-all-on", view: .thisMac, alarmsAll: true, dark: dark, into: directory)
            try render("glance-thismac-all-off", view: .thisMac, alarmsAll: false, dark: dark, into: directory)
            try render("glance-thismac-expanded", view: .thisMac, alarmsAll: true, expanded: ["anthropic"],
                       dark: dark, into: directory)
            try render("glance-fleet-all-on", view: .fleetReported, alarmsAll: true, dark: dark, into: directory)
            try render("glance-fleet-all-off", view: .fleetReported, alarmsAll: false, dark: dark, into: directory)
            try render("glance-fleet-empty", view: .fleetReported, alarmsAll: true, fleet: false,
                       dark: dark, into: directory)
        }
    }
}
