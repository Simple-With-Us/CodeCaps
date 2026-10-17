import AppKit
import XCTest
@testable import CodeCaps

@MainActor
final class PipInteractionTests: XCTestCase {
    func testBodyDragIncludesLogosBarsAndTextButNotResizeEdgesOrControls() {
        let size = NSSize(width: 400, height: 180)
        for point in [NSPoint(x: 18, y: 70), NSPoint(x: 160, y: 110), NSPoint(x: 310, y: 40)] {
            XCTAssertTrue(PipDragMonitor.canStart(at: point, size: size))
        }
        for point in [NSPoint(x: 3, y: 70), NSPoint(x: 399, y: 40), NSPoint(x: 380, y: 165)] {
            XCTAssertFalse(PipDragMonitor.canStart(at: point, size: size))
        }
    }

    func testPinnedRowsExcludeUnselectedMiniMax() {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        model.pipPinnedRowIds = ["anthropic"]
        model.pipAutoAddedRowIds = []
        XCTAssertEqual(PipWidgetController.targetRows(for: model).map(\.id), ["anthropic"])
        model.pipAutoAddedRowIds = ["minimax"]
        XCTAssertEqual(Set(PipWidgetController.targetRows(for: model).map(\.id)), ["anthropic", "minimax"])
        model.pipAutoAddedRowIds = []
        XCTAssertFalse(PipWidgetController.targetRows(for: model).contains { $0.id == "minimax" })
    }

    func testAttachmentPreferencePersistsAndDefaultsToAttached() {
        let suite = "com.jays.codecaps.attachment." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults, presentsPipWindows: false)
        XCTAssertTrue(model.glanceAttachedToMenuBar)
        model.glanceAttachedToMenuBar = false
        XCTAssertFalse(MonitorModel(defaults: defaults, presentsPipWindows: false).glanceAttachedToMenuBar)
    }
}
