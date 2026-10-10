import XCTest
@testable import CodeCaps

/// The PiP HUD's responsive ladder.
///
/// The owner reported (2026-10-05) that a provider with two quota bars did not
/// fit inside the window: the percentage and the reset countdown were cut off
/// on the right.  The fix was a width ladder — show everything when there is
/// room, then drop the least load-bearing element at each step, ending at the
/// floor the owner asked for: one or two bars and their percentages.
///
/// The thresholds are derived from the same constants the view draws with, so
/// these tests pin the *relationships* rather than a set of magic numbers that
/// would drift the moment a constant moved.
@MainActor
final class PipMetricsTests: XCTestCase {

    // MARK: Width ladder

    func testFullDetailNeedsTwoNamedMetersWithCountdowns() {
        let needed = PipMetrics.padding * 2 + PipMetrics.fullMinWidth
        XCTAssertEqual(PipMetrics.detail(forWidth: needed), .full,
                       "A panel exactly wide enough for two named meters with countdowns must show all of it")
        XCTAssertLessThan(PipMetrics.detail(forWidth: needed - 1), .full,
                          "One point narrower must drop below the richest level rather than clip")
    }

    func testEachStepDropsSomethingTheOwnerWouldMiss() {
        // Walk down the ladder and assert every step is strictly poorer, so no
        // two levels render the same thing (a dead rung would be a bug waiting
        // to be mistaken for a working one).
        var width = PipMetrics.maxWidth
        var previous: PipMetrics.Detail? = nil
        while width >= PipMetrics.minWidth {
            let detail = PipMetrics.detail(forWidth: width)
            if let previous, detail != previous {
                XCTAssertLessThan(detail, previous,
                                  "Detail changed from \(previous) to \(detail) at width \(width)")
            }
            previous = detail
            width -= 7
        }
    }

    /// Owner, 2026-10-08: "when the window is getting narrower, the first
    /// thing to go (after things have compressed as much as allowable) is the
    /// platform name ASSUMING WE FINALLY CAN MAKE THE LOGOS ACTUALLY SHOW UP".
    ///
    /// The logo and the name used to drop together at `minimal`, so there was
    /// nothing left to identify the row.  The name now goes first, at its own
    /// `logoOnly` level, and the logo survives until the identity ladder runs
    /// out entirely.
    func testThePlatformNameDropsBeforeTheLogo() {
        XCTAssertTrue(PipMetrics.Detail.logoOnly.showsProviderLogo,
                      "the logo must still identify the row at this level")
        XCTAssertFalse(PipMetrics.Detail.logoOnly.showsTitle,
                       "the name is the first thing to go")

        // And there is a real width band that selects it, between the named
        // single-meter row and the identity-free minimal one.
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.logoOnlyMinWidth),
                       .logoOnly)
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.minimalMinWidth),
                       .minimal)
        XCTAssertFalse(PipMetrics.Detail.minimal.showsProviderLogo,
                       "the logo goes only after the name, at the identity-free end")

        // Nothing above logoOnly may lose the name while keeping two meters.
        for level in [PipMetrics.Detail.full, .noCountdown, .logoOnly] {
            if level.maxMeters > 1 || level == .logoOnly {
                XCTAssertTrue(level.showsProviderLogo, "\(level) must keep the logo")
            }
        }
    }

    func testNarrowWindowStillShowsBarAndPercent() {
        // The owner's floor: only the bars and the percentages remain.
        let detail = PipMetrics.detail(forWidth: PipMetrics.minWidth)
        XCTAssertEqual(detail, .singleBar)
        XCTAssertEqual(detail.maxMeters, 1)
        XCTAssertFalse(detail.showsCountdown)
        XCTAssertFalse(detail.showsCadence)
        XCTAssertFalse(detail.showsTitle)
        XCTAssertFalse(detail.showsProviderLogo)
    }

    func testTwoMeterRowsStayOnScreenAtFullDetail() {
        // The regression that started this: a dual-meter row must fit the width
        // the controller sizes the panel to, or the percentage gets clipped.
        let fit = PipMetrics.fitSize(rowCount: 1, hasDualMeterRow: true)
        let detail = PipMetrics.detail(forWidth: fit.width)
        XCTAssertEqual(detail, .full,
                       "A panel fitted for a dual-meter row must be able to render that row fully")
        XCTAssertEqual(detail.maxMeters, 2)
    }

    func testSingleMeterRowOpensAtAReadableWidth() {
        let fit = PipMetrics.fitSize(rowCount: 1, hasDualMeterRow: false)
        XCTAssertGreaterThanOrEqual(fit.width, PipMetrics.singleMeterDefaultWidth)
        XCTAssertLessThanOrEqual(PipMetrics.detail(forWidth: fit.width), .noCountdown)
    }

    // MARK: Height ladder

    func testFitHeightGrowsWithEveryPinnedRow() {
        let three = PipMetrics.fitSize(rowCount: 3, hasDualMeterRow: false)
        let five = PipMetrics.fitSize(rowCount: 5, hasDualMeterRow: false)
        XCTAssertEqual(five.height - three.height, 2 * PipMetrics.rowHeight,
                       "Two more pinned rows is two more rows of height")
    }

    func testFitHeightHasNoOuterPaddingTerm() {
        // The rows run edge to edge, so the panel height is exactly the rows
        // plus the body's own vertical padding and the top drag strip — there is no
        // header band (owner, 2026-10-08).
        let expected = CGFloat(3) * PipMetrics.rowHeight
            + PipMetrics.bodyVerticalPadding * 2
            + PipMetrics.topDragAreaHeight
        XCTAssertEqual(PipMetrics.fitSize(rowCount: 3, hasDualMeterRow: false).height, expected)
    }

    func testEveryFittedRowIsActuallyVisible() {
        for rows in 1...8 {
            let fit = PipMetrics.fitSize(rowCount: rows, hasDualMeterRow: true)
            XCTAssertEqual(PipMetrics.visibleRowCount(total: rows, height: fit.height), rows,
                           "A panel fitted for \(rows) rows must show all \(rows)")
        }
    }

    func testShorteningHidesRowsRatherThanClippingThem() {
        let fitted = PipMetrics.fitSize(rowCount: 5, hasDualMeterRow: false)
        // A header, one row and the padding: the honest floor.
        let squashed = PipMetrics.minHeight
        XCTAssertEqual(PipMetrics.visibleRowCount(total: 5, height: squashed), 1)
        XCTAssertEqual(PipMetrics.visibleRowCount(total: 5, height: fitted.height), 5)
        XCTAssertGreaterThan(squashed, fitted.height - 4 * PipMetrics.rowHeight - 1,
                             "The floor should still hold one whole row, not a sliver of one")
    }

    func testVisibleRowCountNeverReturnsZeroForRealRows() {
        XCTAssertEqual(PipMetrics.visibleRowCount(total: 3, height: 1), 1,
                       "A HUD shrunk to nothing is still a HUD, so one row survives")
        XCTAssertEqual(PipMetrics.visibleRowCount(total: 0, height: 400), 0,
                       "No rows means no rows, even in a tall panel")
    }

    // MARK: Bounds

    func testFitSizeIsAlwaysInsideThePanelBounds() {
        for rows in [1, 2, 5, 50] {
            for dual in [true, false] {
                let fit = PipMetrics.fitSize(rowCount: rows, hasDualMeterRow: dual)
                XCTAssertGreaterThanOrEqual(fit.width, PipMetrics.minWidth)
                XCTAssertLessThanOrEqual(fit.width, PipMetrics.maxWidth)
                XCTAssertGreaterThanOrEqual(fit.height, PipMetrics.minHeight)
                XCTAssertLessThanOrEqual(fit.height, PipMetrics.maxHeight)
            }
        }
    }

    // MARK: Window behaviour

    func testPanelIsResizableAndBounded() {
        let mask = PipMetrics.panelStyleMask
        XCTAssertTrue(mask.contains(.resizable),
                      "The owner asked for a resizable window; the style mask is what grants it")
        // Owner report 2026-10-08: a blank silver strip sat along the top of the
        // HUD "for no reason".  `.titled` and `.hudWindow` both make AppKit paint
        // a titlebar strip that lives outside the SwiftUI content, and no amount
        // of `titleVisibility` or `fullSizeContentView` removes it — the strip
        // belongs to the window frame.  A borderless panel has no strip at all.
        XCTAssertFalse(mask.contains(.titled),
                       "`.titled` brings back the blank silver strip the owner asked to remove")
        XCTAssertFalse(mask.contains(.hudWindow),
                       "`.hudWindow` paints a titlebar strip outside the content view")
        XCTAssertTrue(mask.contains(.borderless),
                      "the rounded panel is now the whole window, so it must be borderless")
        XCTAssertTrue(mask.contains(.nonactivatingPanel),
                      "the HUD must still not steal focus from the app the owner is using")
        XCTAssertLessThan(PipMetrics.minWidth, PipMetrics.maxWidth)
        XCTAssertLessThan(PipMetrics.minHeight, PipMetrics.maxHeight)
    }
}