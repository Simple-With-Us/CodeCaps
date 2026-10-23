import AppKit
import QuotaCore
import SwiftUI
import XCTest
@testable import CodeCaps

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
}
