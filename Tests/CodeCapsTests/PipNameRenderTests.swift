import AppKit
import QuotaCore
import SwiftUI
import XCTest
@testable import CodeCaps

/// The PiP HUD's own screenshots.
///
/// Not part of CI: with `CODECAPS_DOCS_RENDER_DIR` unset the tests skip.  Run
/// them and copy the files into `docs/screenshots/`:
///
///     CODECAPS_DOCS_RENDER_DIR=/some/dir swift test --filter PipNameRenderTests
///     cp /some/dir/pip-ladder-named-435.png docs/screenshots/pip-hud-named.png
///     cp /some/dir/pip-ladder-unnamed-240.png docs/screenshots/pip-hud-unnamed.png
///     cp /some/dir/pip-ladder-unnamed-160.png docs/screenshots/pip-hud-small.png
///     cp /some/dir/pip-strip-named.png docs/screenshots/pip-hud-strip.png
///     cp /some/dir/pip-detail-260.png docs/screenshots/pip-detail.png
///
/// The pictures exist because the redesign is a set of layout claims, and a
/// layout claim is worth a picture (owner, 2026-10-28).
@MainActor
final class PipNameRenderTests: XCTestCase {
    func testRenderPinnedProviderNamesAtCompactAndNarrowWidths() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_DOCS_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_DOCS_RENDER_DIR to render PiP provider-name screenshots")
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (model, defaults, suite) = GlanceFixtures.makeModel(
            view: .fromMac, alarmsAll: true, fleet: false, localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerKeys: Set<String> = [
            "minimax", "anthropic", "openai", "muse-code", "muse-assist", "cursor", "xai"
        ]
        let pinnedRows = model.displaySections.filter { providerKeys.contains($0.providerKey) }
        XCTAssertEqual(Set(pinnedRows.map(\.providerKey)), providerKeys,
                       "the render fixture must include each screenshot provider")
        model.isPipEnabled = true
        model.pipAutoAddedRowIds = []
        model.pipPinnedRowIds = Set(pinnedRows.map(\.id))

        for width in [CGFloat(425), CGFloat(435), CGFloat(300)] {
            let png = try XCTUnwrap(GlanceFixtures.png(
                of: PipWidgetView(model: model), size: CGSize(width: width, height: 250), dark: false))
            XCTAssertFalse(png.isEmpty, "PiP render at \(width)pt must produce PNG data")
            try png.write(to: directory.appendingPathComponent("pip-provider-names-\(Int(width)).png"))
        }

        for (provider, widths) in [("minimax", [CGFloat(330), CGFloat(375)]), ("openai", [CGFloat(240)])] {
            let windows = GlanceFixtures.localWindows.filter {
                $0.providerKey == provider && (provider != "openai" || $0.id == "codex-7d")
            }
            model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows)
                .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now)
            let row = try XCTUnwrap(model.displaySections.first { $0.providerKey == provider })
            model.pipPinnedRowIds = [row.id]
            for width in widths {
                let png = try XCTUnwrap(GlanceFixtures.png(
                    of: PipWidgetView(model: model), size: CGSize(width: width, height: 100), dark: false))
                XCTAssertFalse(png.isEmpty)
                try png.write(to: directory.appendingPathComponent("pip-single-\(provider)-\(Int(width)).png"))
            }
        }
    }

    /// The redesigned ladder, at every rung, with and without the provider
    /// name.
    ///
    /// Owner 2026-10-28 asked for the logo to survive to the smallest size,
    /// for the bars to sit closer together there, and for the name to be
    /// optional so the room can go to the meters.  Those are layout claims,
    /// and a layout claim is worth a picture (owner, 2026-10-28).
    func testRenderEveryLadderRungWithAndWithoutTheProviderName() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_DOCS_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_DOCS_RENDER_DIR to render the PiP ladder screenshots")
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (model, defaults, suite) = GlanceFixtures.makeModel(
            view: .fromMac, alarmsAll: true, fleet: false, localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerKeys: Set<String> = [
            "minimax", "anthropic", "openai", "muse-code", "muse-assist", "cursor", "xai"
        ]
        let pinnedRows = model.displaySections.filter { providerKeys.contains($0.providerKey) }
        model.isPipEnabled = true
        model.pipAutoAddedRowIds = []
        model.pipPinnedRowIds = Set(pinnedRows.map(\.id))

        // One width per rung: the named row, the countdown rows, the bare
        // meters, and the floor.
        for width in [CGFloat(435), CGFloat(300), CGFloat(240), CGFloat(160), CGFloat(120)] {
            for names in [true, false] {
                model.pipShowProviderNames = names
                let png = try XCTUnwrap(GlanceFixtures.png(
                    of: PipWidgetView(model: model), size: CGSize(width: width, height: 250), dark: false))
                XCTAssertFalse(png.isEmpty)
                let suffix = names ? "named" : "unnamed"
                try png.write(to: directory.appendingPathComponent(
                    "pip-ladder-\(suffix)-\(Int(width)).png"))
            }
        }
    }

    /// The wide strip, which the owner asked to have a rule between the
    /// platforms so it reads as several platforms and not one row of smudges.
    ///
    /// The strip only appears when the panel is too short to stack every
    /// pinned row, so the render is short and wide.
    func testRenderTheWideStripWithItsSeparatorRules() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_DOCS_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_DOCS_RENDER_DIR to render the PiP strip screenshot")
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (model, defaults, suite) = GlanceFixtures.makeModel(
            view: .fromMac, alarmsAll: true, fleet: false, localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerKeys: Set<String> = [
            "minimax", "anthropic", "openai", "muse-code", "muse-assist", "cursor", "xai"
        ]
        let pinnedRows = model.displaySections.filter { providerKeys.contains($0.providerKey) }
        model.isPipEnabled = true
        model.pipAutoAddedRowIds = []
        model.pipPinnedRowIds = Set(pinnedRows.map(\.id))

        for names in [true, false] {
            model.pipShowProviderNames = names
            let png = try XCTUnwrap(GlanceFixtures.png(
                of: PipWidgetView(model: model), size: CGSize(width: 520, height: 60), dark: false))
            XCTAssertFalse(png.isEmpty)
            try png.write(to: directory.appendingPathComponent(
                "pip-strip-\(names ? "named" : "unnamed").png"))
        }
    }

    /// The expanded platform detail: one line per window, with the percentage
    /// and the time remaining on either side of a narrower bar, and the rows
    /// opening out when the panel has room to spare.
    func testRenderTheExpandedPlatformDetail() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_DOCS_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_DOCS_RENDER_DIR to render the PiP detail screenshot")
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (model, defaults, suite) = GlanceFixtures.makeModel(
            view: .fromMac, alarmsAll: true, fleet: false, localReadersOn: true)
        defer { defaults.removePersistentDomain(forName: suite) }

        model.isPipEnabled = true
        model.pipAutoAddedRowIds = []
        let row = try XCTUnwrap(model.displaySections.first { $0.providerKey == "anthropic" })
        model.pipPinnedRowIds = [row.id]

        for height in [CGFloat(120), CGFloat(260)] {
            let png = try XCTUnwrap(GlanceFixtures.png(
                of: PipWidgetView(model: model, opensDetailRowId: row.id),
                size: CGSize(width: 460, height: height), dark: false))
            XCTAssertFalse(png.isEmpty)
            try png.write(to: directory.appendingPathComponent(
                "pip-detail-\(Int(height)).png"))
        }
    }
}
