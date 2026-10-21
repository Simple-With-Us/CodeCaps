import AppKit
import QuotaCore
import XCTest
@testable import CodeCaps

/// The default PiP target set is what the HUD can honestly draw.  These cover
/// the rule that a provider whose refresh failed is not a default target, and
/// that the HUD still shows status rows when it has nothing else to show.
@MainActor
final class PipTargetSelectionTests: XCTestCase {
    /// A provider whose refresh failed cannot describe the current allowance,
    /// so it never takes a default target from a provider that can.
    func testAFailedProviderIsNotADefaultTarget() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = [
            GlanceFixtures.window("anthropic:5h", provider: "anthropic", label: "5-hour window",
                token: "5h", remaining: 13, resetIn: 3_600),
            GlanceFixtures.window("google-antigravity:gemini:weekly", provider: "google-antigravity",
                label: "Gemini Models · Weekly", token: "weekly", remaining: 54, resetIn: 86_400)
        ]
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows)
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now,
            issues: ["google-antigravity": "Helper failed"])
        model.pipPinnedRowIds = []
        model.pipAutoAddedRowIds = []
        let rows = PipWidgetController.targetRows(for: model)
        XCTAssertFalse(rows.contains { $0.providerKey == "google-antigravity" })
        XCTAssertTrue(rows.contains { $0.providerKey == "anthropic" })
    }

    /// A failed provider the user pinned still shows, and it reports its
    /// status rather than a cached quota.
    func testAPinnedFailedProviderStillShowsItsStatus() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = [GlanceFixtures.window("google-antigravity:gemini:weekly", provider: "google-antigravity",
            label: "Gemini Models · Weekly", token: "weekly", remaining: 54, resetIn: 86_400)]
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows)
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now,
            issues: ["google-antigravity": "Helper failed"])
        let row = try XCTUnwrap(model.displaySections.first { $0.providerKey == "google-antigravity" })
        model.pipPinnedRowIds = [row.id]
        XCTAssertEqual(PipWidgetController.targetRows(for: model).map(\.id), [row.id])
        XCTAssertEqual(PipWidgetController.readingStatus(for: row, now: model.now,
            issue: model.issues[row.providerKey]), "unavailable")
        XCTAssertEqual(PipWidgetController.meterCount(for: row, now: model.now,
            issue: model.issues[row.providerKey]), 0)
    }
}
