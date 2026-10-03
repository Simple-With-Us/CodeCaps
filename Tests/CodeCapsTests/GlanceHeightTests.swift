import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// The popover's height is computed, not measured, so a constant left out of
/// the sum shows up as a list that scrolls by a few points, or as a header and
/// footer clipped out of a snapshot.  These pin the arithmetic against the
/// list SwiftUI actually lays out.
@MainActor
final class GlanceHeightTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iso = ISO8601DateFormatter()
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "com.jays.codecaps.height." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "localEnabled")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func window(_ id: String, provider: String, label: String, token: String, remaining: Double,
                        resetIn: TimeInterval) -> QuotaWindow {
        QuotaWindow(id: id, provider: provider, providerKey: provider, label: label,
                    remainingPercent: remaining,
                    resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
                    window: token,
                    occurredAt: iso.string(from: now.addingTimeInterval(-60)),
                    source: provider)
    }

    /// Every expected provider reporting a short and a long window, plus the
    /// second Antigravity pool, so the list has as many rows as it will ever
    /// be budgeted for.
    private var fullyReportingWindows: [QuotaWindow] {
        var windows: [QuotaWindow] = []
        for key in expectedQuotaProviderKeys where key != AntigravityDisplay.providerKey {
            windows.append(window("\(key):5h", provider: key, label: "5-hour window", token: "5h",
                                  remaining: 80, resetIn: 3_600))
            windows.append(window("\(key):7d", provider: key, label: "Weekly window", token: "weekly",
                                  remaining: 60, resetIn: 4 * 86_400))
        }
        for pool in ["gemini", "third-party"] {
            windows.append(window("antigravity:\(pool):5h", provider: AntigravityDisplay.providerKey,
                                  label: "\(pool == "gemini" ? "Gemini" : "Third-Party") Models · 5-hour",
                                  token: "5h", remaining: 70, resetIn: 3_600))
            windows.append(window("antigravity:\(pool):weekly", provider: AntigravityDisplay.providerKey,
                                  label: "\(pool == "gemini" ? "Gemini" : "Third-Party") Models · Weekly",
                                  token: "weekly", remaining: 50, resetIn: 4 * 86_400))
        }
        return windows
    }

    private func makeModel(view: GlanceViewMode) -> MonitorModel {
        let model = MonitorModel(defaults: defaults)
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: fullyReportingWindows)
                                .platformSections(now: now), now: now)
        model.injectFleetForTests(groups: [
            FleetWindowGroup(id: "mini", title: "Mac mini", windows: [
                window("mini:claude:5h", provider: "anthropic", label: "5-hour window", token: "5h",
                       remaining: 40, resetIn: 3_600),
                window("mini:claude:7d", provider: "anthropic", label: "7-day window", token: "168h",
                       remaining: 30, resetIn: 2 * 86_400),
                window("mini:codex:5h", provider: "openai", label: "5-hour window", token: "5h",
                       remaining: 90, resetIn: 3_600),
            ]),
            FleetWindowGroup(id: "box", title: "build-box", windows: [
                window("box:cursor:plan", provider: "cursor", label: "Included plan", token: "billing-cycle",
                       remaining: 60, resetIn: 9 * 86_400),
            ]),
        ], checkedAt: now)
        model.glanceView = view
        return model
    }

    // MARK: Arithmetic

    func testRowsCountTheirHairlinesAndTheCardItsGap() {
        // Eight rows: 8 * Metrics.glanceLocalRowHeight + 7 hairlines, then a 12pt gap and the 52pt card.
        let withCard = QuotaGlanceMetrics.localListHeight(rows: 8, showsSetupCard: true, isEmpty: false)
        let withoutCard = QuotaGlanceMetrics.localListHeight(rows: 8, showsSetupCard: false, isEmpty: false)
        let none = QuotaGlanceMetrics.localListHeight(rows: 0, showsSetupCard: false, isEmpty: false)
        let rows: CGFloat = 8 * Metrics.glanceLocalRowHeight + 7
        XCTAssertEqual(withCard, rows + 12 + 52)
        XCTAssertEqual(withoutCard, rows)
        XCTAssertEqual(none, 0)
    }

    func testFleetGroupsCountHeadingsGapsAndHairlines() {
        // Two groups of 3 and 1 rows: two 22pt heading bands, one 6pt gap,
        // 4 rows, 2 hairlines.
        let two = QuotaGlanceMetrics.fleetListHeight(rowsPerGroup: [3, 1])
        let empty = QuotaGlanceMetrics.fleetListHeight(rowsPerGroup: [])
        let expected: CGFloat = 44 + 6 + (4 * Metrics.glanceLocalRowHeight) + 2
        XCTAssertEqual(two, expected)
        XCTAssertEqual(empty, Metrics.glanceEmptyStateHeight)
    }

    func testThePopoverAddsItsChromeAroundTheList() {
        // Header 40 + footer 38 + two 1pt dividers + 8pt above and below the list.
        let total = QuotaGlanceMetrics.popoverHeight(forListHeight: 100)
        let expected: CGFloat = 40 + 38 + 2 + 16 + 100
        XCTAssertEqual(total, expected)
    }

    // MARK: Against the real layout

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    /// Lays the real popover out at the height it was budgeted and returns how
    /// far its list overflows the scroll area, in points.
    private func overflow(of view: GlanceViewMode) throws -> CGFloat {
        let model = makeModel(view: view)
        let height = QuotaGlanceMetrics.popoverHeight(for: model)
        let popover = GlancePopover(model: model, openConsole: { _ in }, openSettings: {})
        let host = NSHostingView(rootView: popover)
        host.frame = NSRect(x: 0, y: 0, width: Metrics.glanceWidth, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let scroll = scrollView(in: host), let document = scroll.documentView else {
            throw XCTSkip("SwiftUI did not build an NSScrollView in this session")
        }
        return document.frame.height - scroll.contentSize.height
    }

    func testFromMacListFitsItsScrollAreaWithoutScrolling() throws {
        let extra = try overflow(of: .fromMac)
        XCTAssertLessThanOrEqual(extra, 0.5, "From Mac's list overflows the popover by \(extra)pt")
    }

    func testFromFleetListFitsItsScrollAreaWithoutScrolling() throws {
        let extra = try overflow(of: .fromFleet)
        XCTAssertLessThanOrEqual(extra, 0.5, "From Fleet's list overflows the popover by \(extra)pt")
    }
}
