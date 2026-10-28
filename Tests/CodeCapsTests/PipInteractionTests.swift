import AppKit
import QuotaCore
import XCTest
@testable import CodeCaps

@MainActor
final class PipInteractionTests: XCTestCase {
    func testExplicitSkippedNonzeroReadingIsUnavailableButZeroRemainsVisible() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        var skipped = GlanceFixtures.window("anthropic:5h", provider: "anthropic",
            label: "5h", token: "5h", remaining: 54, resetIn: 18_000)
        skipped.skip = true
        for percent in [54.0, 0.0] {
            skipped.remainingPercent = percent
            model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: [skipped])
                .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now)
            let row = try XCTUnwrap(model.displaySections.first { $0.id == "anthropic" })
            let current = PipWidgetController.currentWindows(for: row, now: model.now)
            XCTAssertEqual(current.count, percent == 0 ? 1 : 0)
            XCTAssertEqual(PipWidgetController.readingStatus(for: row, now: model.now),
                           percent == 0 ? nil : "unavailable")
        }
    }

    /// Owner 2026-10-28: "Muse assist says at 7 day cap but doesn't mention the
    /// extra quota so it isn't stopped really and needs to reflect that in PiP
    /// like it does in menu bar window."
    ///
    /// The extra allowance is a *count*, not a percentage: it has no cap and no
    /// reset date, so the HUD's own meter filter dropped it and the row said
    /// "At Cap" while the plan could still be used.
    func testMuseExtraBalanceIsFoundEvenThoughTheMeterFilterDropsIt() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let weekly = GlanceFixtures.window("muse-assist:weekly", provider: "muse-assist",
            label: "weekly", token: "7d", remaining: 0,
            resetIn: GlanceFixtures.day + 2 * GlanceFixtures.hour)
        var extra = GlanceFixtures.window("muse-assist:extra", provider: "muse-assist",
            label: "Extra tokens", token: nil, remaining: nil, resetIn: nil)
        extra.absoluteRemaining = 42

        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: [weekly, extra])
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now)
        let row = try XCTUnwrap(model.displaySections.first { $0.id == "muse-assist" })

        // The meter filter drops the counted balance: a count is not a quota.
        let current = PipWidgetController.currentWindows(for: row, now: model.now)
        XCTAssertFalse(current.contains { $0.window.id == "muse-assist:extra" },
                       "the counted balance is not a meter")

        // But the row can still spend it.
        let usable = PipWidgetController.usableMuseExtra(for: row, now: model.now)
        XCTAssertEqual(usable?.window.id, "muse-assist:extra",
                       "the extra balance must be found, or the HUD says the plan is stopped")

        // And the plan really is at its weekly cap: the extra balance does not
        // undo the cap, it only says the plan is still usable.
        let cap = QuotaPlatformSection(providerKey: row.providerKey,
                                       providerLabel: row.section.providerLabel,
                                       expected: row.section.expected,
                                       windows: current).atCapWindow()
        XCTAssertEqual(cap?.window.id, "muse-assist:weekly")
    }

    /// A failed provider claims nothing, not even an extra balance.
    func testAFailedProviderHasNoExtraBalanceToSpend() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let weekly = GlanceFixtures.window("muse-assist:weekly", provider: "muse-assist",
            label: "weekly", token: "7d", remaining: 0,
            resetIn: GlanceFixtures.day + 2 * GlanceFixtures.hour)
        var extra = GlanceFixtures.window("muse-assist:extra", provider: "muse-assist",
            label: "Extra tokens", token: nil, remaining: nil, resetIn: nil)
        extra.absoluteRemaining = 42

        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: [weekly, extra])
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now)
        let row = try XCTUnwrap(model.displaySections.first { $0.id == "muse-assist" })

        XCTAssertNil(PipWidgetController.usableMuseExtra(for: row, now: model.now, issue: "signed out"))
    }

    /// A window that is at its cap is still a window the panel shows.
    ///
    /// The shared cap rule calls any reading at or under 0.5% spent, because
    /// the interface rounds a reading to the nearest whole percent.  When the
    /// export also hid such a window, the picture in picture dropped it and
    /// its cap line while the menu bar still announced the cap, so the same
    /// window was live in one place and gone in the other.
    func testANearZeroReadingStaysVisibleInThePictureInPicture() throws {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = GlanceFixtures.window("anthropic:5h", provider: "anthropic",
            label: "5h", token: "5h", remaining: 0.3, resetIn: 18_000)
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: [window])
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now)
        let row = try XCTUnwrap(model.displaySections.first { $0.id == "anthropic" })

        let current = PipWidgetController.currentWindows(for: row, now: model.now)
        XCTAssertEqual(current.count, 1, "a window at 0.3% is at its cap, not a reading to hide")
        XCTAssertEqual(current.first?.remainingPercent, 0.3)
        XCTAssertNil(PipWidgetController.readingStatus(for: row, now: model.now))

        // The cap line is built from the same filtered list, so it has to be
        // there too:  a spent window that is visible still says it is spent.
        let section = QuotaPlatformSection(providerKey: row.providerKey,
                                           providerLabel: row.section.providerLabel,
                                           expected: row.section.expected,
                                           windows: current)
        XCTAssertNotNil(section.atCapWindow(), "the cap line still reads the shared cap rule")
    }

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
        // The demo model plus a failed Antigravity provider.  The weekly
        // reading is the cached 54 percent the owner saw in a screenshot, and
        // the provider fails to refresh it.
        let windows = GlanceFixtures.localWindows.map { window in
            window.id == "antigravity:gemini:weekly"
                ? GlanceFixtures.window("antigravity:gemini:weekly", provider: "google-antigravity",
                    label: "Gemini Models · Weekly", token: "weekly", remaining: 54, resetIn: 86_400)
                : window
        }
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
        // Unpinning releases the row, but the panel does not go blank: the
        // automatic selection falls back to the rows it can honestly measure,
        // the rule testAllUnavailableFallbackStillShowsStatusRows asserts.
        // What matters is that the failed provider never comes back with the
        // cached 54 percent, and that every listed row is drawn honestly.
        model.pipPinnedRowIds = []
        let rows = PipWidgetController.targetRows(for: model)
        XCTAssertFalse(rows.isEmpty, "the panel must not go blank when the failed row is released")
        XCTAssertFalse(rows.contains { $0.id == row.id },
            "the failed row must not be listed: it would show the cached 54 percent")
        for candidate in rows {
            let candidateIssue = model.issues[candidate.providerKey]
            let status = PipWidgetController.readingStatus(for: candidate, now: model.now,
                issue: candidateIssue)
            let meters = PipWidgetController.meterSnapshots(for: candidate, now: model.now,
                issue: candidateIssue)
            if candidateIssue != nil {
                XCTAssertNotNil(status, "\(candidate.id) must carry a status, never a live meter")
                XCTAssertTrue(meters.isEmpty, "\(candidate.id) must not draw a cached meter")
            } else if status == nil {
                XCTAssertFalse(meters.isEmpty, "\(candidate.id) must show its live meters")
            } else {
                XCTAssertTrue(meters.isEmpty,
                    "\(candidate.id) must not draw meters for a row that only reports a status")
            }
        }
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

    func testAllUnavailableFallbackStillShowsStatusRows() {
        let (model, defaults, suite) = GlanceFixtures.makeModel(view: .fromMac, alarmsAll: false, fleet: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = GlanceFixtures.localWindows
        let issues = Dictionary(uniqueKeysWithValues: Set(windows.map(\.canonicalProviderKey)).map { ($0, "Unavailable") })
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows)
            .platformSections(now: GlanceFixtures.now), now: GlanceFixtures.now, issues: issues)
        model.pipPinnedRowIds = []
        model.pipAutoAddedRowIds = []
        let rows = PipWidgetController.targetRows(for: model)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy {
            PipWidgetController.readingStatus(for: $0, now: model.now, issue: model.issues[$0.providerKey]) != nil
        })
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
