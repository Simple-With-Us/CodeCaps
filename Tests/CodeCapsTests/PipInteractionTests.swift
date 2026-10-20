import AppKit
import QuotaCore
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

    func testDragUsesScreenCoordinatesWithoutMovingItsOwnReferencePoint() {
        let origin = PipDragMonitor.movedOrigin(start: NSPoint(x: 500, y: 300),
                                               mouseStart: NSPoint(x: 600, y: 350), mouseNow: NSPoint(x: 680, y: 320))
        XCTAssertEqual(origin, NSPoint(x: 580, y: 270))
    }

    func testBodyDragMovesARealPanelAndConsumesDragWithoutOpeningDetails() throws {
        let panel = NSPanel(contentRect: NSRect(x: 400, y: 300, width: 430, height: 180),
                            styleMask: PipMetrics.panelStyleMask, backing: .buffered, defer: false)
        let monitor = PipDragMonitor(window: panel)
        let start = panel.frame.origin
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 80, y: 60),
                modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertNotNil(monitor.handle(try event(.leftMouseDown), screenPoint: NSPoint(x: 480, y: 360)))
        XCTAssertNotNil(monitor.handle(try event(.leftMouseDragged), screenPoint: NSPoint(x: 481, y: 361)))
        XCTAssertEqual(panel.frame.origin, start)
        XCTAssertNil(monitor.handle(try event(.leftMouseDragged), screenPoint: NSPoint(x: 560, y: 330)))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: start.x + 80, y: start.y - 30))
        XCTAssertNil(monitor.handle(try event(.leftMouseUp), screenPoint: NSPoint(x: 560, y: 330)))
        panel.close()
    }

    func testMuseReadingsProducePipMeters() {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["muse-assist", "muse-code"] {
            let row = model.displaySections.first { $0.id == key }
            XCTAssertNotNil(row)
            if let row { XCTAssertGreaterThan(PipWidgetController.meterCount(for: row, now: model.now), 0) }
        }
    }

    func testFailedAntigravityReadingStaysPinnedWithoutShowingCachedQuota() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = [GlanceFixtures.window("antigravity:gemini:weekly", provider: "google-antigravity",
            label: "Gemini Models · Weekly", token: "weekly", remaining: 54, resetIn: 86_400)]
        let sections = QuotaResponse(generatedAt: "", windows: windows).platformSections(now: GlanceFixtures.now)
        model.injectForTests(sections: sections, now: GlanceFixtures.now,
                             issues: ["google-antigravity": "Helper failed"])
        let row = try XCTUnwrap(model.displaySections.first { $0.poolKey == "gemini" })
        model.pipPinnedRowIds = [row.id]
        XCTAssertEqual(PipWidgetController.targetRows(for: model).map(\.id), [row.id])
        XCTAssertEqual(PipWidgetController.readingStatus(for: row, now: model.now,
            issue: model.issues[row.providerKey]), "unavailable")
        XCTAssertTrue(PipWidgetController.meterSnapshots(for: row, now: model.now,
            issue: model.issues[row.providerKey]).isEmpty)
        XCTAssertEqual(PipWidgetController.meterCount(for: row, now: model.now,
            issue: model.issues[row.providerKey]), 0)
        model.pipPinnedRowIds = []
        XCTAssertFalse(PipWidgetController.targetRows(for: model).contains { $0.id == row.id })
    }

    func testStaleOrDisabledReadingCannotDrawCurrentMeters() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let row = try XCTUnwrap(model.displaySections.first { $0.id == "anthropic" })
        XCTAssertFalse(PipWidgetController.meterSnapshots(for: row, now: model.now).isEmpty)
        XCTAssertEqual(PipWidgetController.readingStatus(for: row, now: model.now.addingTimeInterval(3_600)),
                       "stale reading")
        XCTAssertTrue(PipWidgetController.meterSnapshots(for: row,
            now: model.now.addingTimeInterval(3_600)).isEmpty)
        XCTAssertEqual(PipWidgetController.readingStatus(for: row, now: model.now,
            disabledSources: ["anthropic"]), "source disabled")
        XCTAssertTrue(PipWidgetController.meterSnapshots(for: row, now: model.now,
            disabledSources: ["anthropic"]).isEmpty)
        XCTAssertEqual(PipWidgetController.meterCount(for: row, now: model.now,
            disabledSources: ["anthropic"]), 0)
    }

    func testFreshWeeklyCapRemainsVisibleBesideFullShortWindow() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = [
            GlanceFixtures.window("antigravity:gemini:5h", provider: "google-antigravity",
                label: "Gemini Models · 5-hour", token: "5h", remaining: 100, resetIn: 18_000),
            GlanceFixtures.window("antigravity:gemini:weekly", provider: "google-antigravity",
                label: "Gemini Models · Weekly", token: "weekly", remaining: 0, resetIn: 86_400)
        ]
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows)
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now)
        let row = try XCTUnwrap(model.displaySections.first { $0.poolKey == "gemini" })
        XCTAssertNil(PipWidgetController.readingStatus(for: row, now: model.now))
        let current = PipWidgetController.currentWindows(for: row, now: model.now)
        XCTAssertEqual(current.first { $0.window.window == "weekly" }?.remainingPercent, 0)
        XCTAssertEqual(row.atCapWindow?.remainingPercent, 0)
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
