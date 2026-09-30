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

    private func console(page: ConsolePage, dark: Bool) -> Data? {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: true, fleet: false,
                                                                localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = ConsoleState(defaults: defaults)
        state.page = page
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
        try write(console(page: .allPlatforms, dark: false), "console-light.png", to: directory)
        try write(console(page: .allPlatforms, dark: true), "console-dark.png", to: directory)
        try write(console(page: .platform("google-antigravity:gemini"), dark: false),
                  "platform-antigravity.png", to: directory)
        try write(console(page: .settingsSourcesFleet, dark: false), "settings-sources-fleet.png", to: directory)
    }
}
