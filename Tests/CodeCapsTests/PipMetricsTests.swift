import AppKit
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
    /// The logo and the name used to drop together, so there was nothing left
    /// to identify the row.  The name now goes first, at its own `logoOnly`
    /// level, and the logo survives all the way to the floor.
    func testThePlatformNameDropsBeforeTheLogo() {
        XCTAssertTrue(PipMetrics.Detail.logoOnly.showsProviderLogo,
                      "the logo must still identify the row at this level")
        XCTAssertFalse(PipMetrics.Detail.logoOnly.showsTitle,
                       "the name is the first thing to go")

        // And there is a real width band that selects it.
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.logoOnlyMinWidth),
                       .logoOnly)
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.logoBareMetersMinWidth),
                       .logoBareMeters)

        // Owner 2026-10-28: the logo is 14 points and the name is up to 150.
        // The meters need the room more, but a row with no logo is a row
        // nobody can identify, so the logo survives every level.
        for level in PipMetrics.Detail.allCases {
            XCTAssertTrue(level.showsProviderLogo, "\(level) must keep the logo")
        }
    }

    /// Owner 2026-10-17: On the PiP window make the platform name disappear and
    /// go to just the logos when it gets smaller instead of having the remaining
    /// time disappear first.  Then degrade the remaining time to a single rounded-up
    /// unit before dropping countdowns entirely.
    func testPlatformNameDropsBeforeCountdownAndDegradesToCompactUnit() {
        let fullWidth = PipMetrics.padding * 2 + PipMetrics.fullMinWidth
        XCTAssertEqual(PipMetrics.detail(forWidth: fullWidth), .full)
        XCTAssertTrue(PipMetrics.detail(forWidth: fullWidth).showsTitle)
        XCTAssertTrue(PipMetrics.detail(forWidth: fullWidth).showsCountdown)
        XCTAssertFalse(PipMetrics.detail(forWidth: fullWidth).usesCompactCountdown)

        // Below full width: platform name disappears to logos only, but countdown remains!
        let fullCountdownWidth = PipMetrics.padding * 2 + PipMetrics.logoWithCountdownMinWidth
        let belowFull = PipMetrics.detail(forWidth: fullWidth - 1)
        XCTAssertEqual(belowFull, .logoWithFullCountdown)
        XCTAssertFalse(belowFull.showsTitle, "platform name must drop first")
        XCTAssertTrue(belowFull.showsProviderLogo, "logos must stay")
        XCTAssertTrue(belowFull.showsCountdown, "countdown must not disappear first")
        XCTAssertFalse(belowFull.usesCompactCountdown)

        // Narrower still: countdown degrades to 1-unit rounded up.
        let compactWidth = PipMetrics.padding * 2 + PipMetrics.logoWithCompactCountdownMinWidth
        let compactDetail = PipMetrics.detail(forWidth: fullCountdownWidth - 1)
        XCTAssertEqual(compactDetail, .logoWithCompactCountdown)
        XCTAssertFalse(compactDetail.showsTitle)
        XCTAssertTrue(compactDetail.showsProviderLogo)
        XCTAssertTrue(compactDetail.showsCountdown)
        XCTAssertTrue(compactDetail.usesCompactCountdown, "must use compact single-unit countdown")

        // Narrower still: countdowns drop, logo remains.
        let logoOnlyDetail = PipMetrics.detail(forWidth: compactWidth - 1)
        XCTAssertEqual(logoOnlyDetail, .logoOnly)
        XCTAssertFalse(logoOnlyDetail.showsTitle)
        XCTAssertTrue(logoOnlyDetail.showsProviderLogo)
        XCTAssertFalse(logoOnlyDetail.showsCountdown, "countdowns drop after compact countdown")
    }

    /// Owner 2026-10-17: "when it gets small enough that it can't have the time
    /// remaining with 2 types of time (days hours or hours minutes) then lets first
    /// go down to just one type of time rounded up so 1.2 hours (1hr 12min) would
    /// say 2h and 59min would say 59min and 2d 2h would say 3d".
    func testCompactCountdownRoundsUpToSingleUnit() {
        let now = Date()

        // 1.2 hours (1hr 12min = 72m) -> 2h
        let onePointTwoHours = now.addingTimeInterval(72 * 60)
        XCTAssertEqual(glanceResetCompactCountdown(onePointTwoHours, now: now), "2h")

        // 59 minutes -> 59m
        let fiftyNineMins = now.addingTimeInterval(59 * 60)
        XCTAssertEqual(glanceResetCompactCountdown(fiftyNineMins, now: now), "59m")

        // 2d 2h (3000 mins) -> 3d
        let twoDaysTwoHours = now.addingTimeInterval((2 * 1440 + 2 * 60) * 60)
        XCTAssertEqual(glanceResetCompactCountdown(twoDaysTwoHours, now: now), "3d")

        // Exactly 1 hour -> 1h
        let oneHour = now.addingTimeInterval(60 * 60)
        XCTAssertEqual(glanceResetCompactCountdown(oneHour, now: now), "1h")

        // Exactly 2 days -> 2d
        let twoDays = now.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(glanceResetCompactCountdown(twoDays, now: now), "2d")

        // Sub-minute -> <1m
        let subMinute = now.addingTimeInterval(45)
        XCTAssertEqual(glanceResetCompactCountdown(subMinute, now: now), "<1m")

        // Expired -> due
        let expired = now.addingTimeInterval(-10)
        XCTAssertEqual(glanceResetCompactCountdown(expired, now: now), "due")
    }

    /// Owner 2026-10-10: "once it gets to where it is in the screenshot or
    /// actually 80-100 pixels wider than that so that it could still have
    /// platform logos at the left … we could make it scroll left to right like
    /// it now does up and down."
    ///
    /// The threshold is derived from the row's own width at the detail level in
    /// force rather than hardcoded to his 80-100 figure, because that figure is
    /// only meaningful while the bar metrics behind it hold. The derived value
    /// lands in his range: the squeeze point is about 222pt, and this is
    /// roughly 90pt past it.
    func testRowsScrollSidewaysOnlyWhenOneFullRowAndAPeekFit() {
        // The threshold is derived from the richest row so it is monotonic in
        // panel width: a per-detail threshold flipped the strip on and off as
        // a resize crossed the detail ladder (owner 2026-10-16).
        let threshold = PipMetrics.padding * 2 + PipMetrics.rowWidth(for: .full) + PipMetrics.horizontalPeek

        XCTAssertFalse(PipMetrics.rowsScrollHorizontally(forWidth: threshold - 1),
                       "one point short of a full row plus a peek stays vertical")
        XCTAssertTrue(PipMetrics.rowsScrollHorizontally(forWidth: threshold))
        XCTAssertGreaterThanOrEqual(PipMetrics.horizontalPeek, 60)
        XCTAssertLessThanOrEqual(PipMetrics.horizontalPeek, 140)

        // Monotonic across the whole resizable range: once wide enough it
        // never flips back.
        for w in stride(from: threshold, through: PipMetrics.maxWidth, by: 7) {
            XCTAssertTrue(PipMetrics.rowsScrollHorizontally(forWidth: w),
                          "width \(w) past the threshold must stay horizontal-capable")
        }
    }

    /// Kody caught this on #208: the flame beside the logo added width that
    /// `rowWidth(for:)` did not know about, so it was clipped in the vertical
    /// list and overflowed the fixed frame in the horizontal strip.
    func testARowCarryingAFlameIsWiderThanOneWithout() {
        for level in PipMetrics.Detail.allCases {
            XCTAssertEqual(
                PipMetrics.rowWidth(for: level, hasFlame: true) - PipMetrics.rowWidth(for: level),
                level.showsProviderLogo ? PipMetrics.flameWidth : 0,
                "\(level) must reserve exactly the flame's width when it draws one")
        }
        XCTAssertGreaterThan(PipMetrics.flameWidth, 0, "the flame is not free")
    }

    func testNarrowWindowStillShowsBarAndPercent() {
        // The owner's floor: the logo, one bar and its percentage remain.
        let detail = PipMetrics.detail(forWidth: PipMetrics.minWidth)
        XCTAssertEqual(detail, .logoSingleMeter)
        XCTAssertEqual(detail.maxMeters, 1)
        XCTAssertFalse(detail.showsCountdown)
        XCTAssertFalse(detail.showsCadence)
        XCTAssertFalse(detail.showsTitle)
        XCTAssertTrue(detail.showsProviderLogo,
                      "the logo must survive to the smallest window the owner can drag to")
    }

    /// Owner 2026-10-28: "the smallest PiP window sizes need rethinking like
    /// those bars can be closer and logo can fit in 3rd screenshot".
    func testTheSmallestWindowStillCarriesTheLogoAndTwoBareMeters() {
        let bare = PipMetrics.padding * 2 + PipMetrics.logoBareMetersMinWidth
        let detail = PipMetrics.detail(forWidth: bare)
        XCTAssertEqual(detail, .logoBareMeters)
        XCTAssertTrue(detail.showsProviderLogo)
        XCTAssertEqual(detail.maxMeters, 2)
        XCTAssertFalse(detail.showsCadence, "the caption is the first thing a bare meter drops")
        XCTAssertFalse(detail.showsCountdown)

        // The bars sit closer together than they used to: a bare meter has no
        // caption to be separated from, so it starts straight at the bar.
        XCTAssertLessThan(PipMetrics.bareMeterMinWidth, PipMetrics.meterMinWidth)
        XCTAssertLessThan(PipMetrics.logoBareMetersMinWidth, PipMetrics.logoOnlyMinWidth)
    }

    /// The meter's reserved width has to match what the meter draws, or the
    /// ladder promises room the row does not have.
    func testMeterWidthsMatchTheMetresTheyReserve() {
        XCTAssertEqual(PipMetrics.meterMinWidth,
                       PipMetrics.cadenceWidth + PipMetrics.meterSpacing + PipMetrics.barMinWidth
                       + PipMetrics.meterSpacing + PipMetrics.percentWidth)
        XCTAssertEqual(PipMetrics.meterMinWidthWithCountdown,
                       PipMetrics.meterMinWidth + PipMetrics.countdownGap + PipMetrics.countdownWidth)
        XCTAssertEqual(PipMetrics.meterMinWidthWithCompactCountdown,
                       PipMetrics.meterMinWidth + PipMetrics.countdownGap + PipMetrics.countdownCompactWidth)
        XCTAssertEqual(PipMetrics.bareMeterMinWidth,
                       PipMetrics.barMinWidth + PipMetrics.meterSpacing + PipMetrics.percentWidth)
    }

    /// A row that publishes one meter must not land on the level that draws
    /// two: that level would render exactly like the level below it.
    func testNoTwoLevelsRenderTheSameRow() {
        // The bare two-meter level and the one-meter level differ only by how
        // many meters they draw, so for a one-meter row they are the same row.
        XCTAssertEqual(PipMetrics.rowWidth(for: .logoBareMeters, meterCount: 1),
                       PipMetrics.rowWidth(for: .logoSingleMeter, meterCount: 1),
                       "these two levels would render the same row, which is why one of them is skipped")

        for width in stride(from: PipMetrics.minWidth, through: PipMetrics.maxWidth, by: 1) {
            let one = PipMetrics.detail(forWidth: width, meterCount: 1)
            XCTAssertNotEqual(one, .logoBareMeters,
                              "the two-meter level must be skipped for a row that publishes one meter")
            XCTAssertTrue(one.showsProviderLogo)
            XCTAssertLessThanOrEqual(one.maxMeters, 2)
        }
        XCTAssertNotEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.logoBareMetersMinWidth,
                                             meterCount: 1),
                          .logoBareMeters)
        // And the two-meter row does get it, at the same width.
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.logoBareMetersMinWidth,
                                          meterCount: 2),
                       .logoBareMeters)
    }

    /// Owner 2026-10-28: "lets make showing the name (when it fits) optional in
    /// PiP settings since I'd rather never show the name instead of showing it
    /// when in PiP so that more room for other parts."
    func testProviderNamesCanBeSuppressedEntirely() {
        for width in stride(from: PipMetrics.minWidth, through: PipMetrics.maxWidth, by: 3) {
            let detail = PipMetrics.detail(forWidth: width, allowsTitle: false)
            XCTAssertNotEqual(detail, .full,
                              "a row that may not print its name must never pick the level that carries it")
            XCTAssertFalse(detail.showsTitle)
            XCTAssertTrue(detail.showsProviderLogo,
                          "the logo is still worth 14 points, even with no name")
        }
        // With no name to carry, the ladder starts one rung lower, so the same
        // panel buys more meter.
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.fullMinWidth,
                                          allowsTitle: false),
                       .logoWithFullCountdown)
        XCTAssertEqual(PipMetrics.detail(forWidth: PipMetrics.padding * 2 + PipMetrics.logoWithCountdownMinWidth,
                                          allowsTitle: false),
                       .logoWithFullCountdown)
    }

    /// With no name on the row, the strip starts scrolling sooner: the row it
    /// has to fit is narrower.
    func testTheHorizontalThresholdFollowsTheNameSetting() {
        let namedThreshold = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .full) + PipMetrics.horizontalPeek
        let unnamedThreshold = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .logoWithFullCountdown) + PipMetrics.horizontalPeek
        XCTAssertLessThan(unnamedThreshold, namedThreshold)
        XCTAssertFalse(PipMetrics.rowsScrollHorizontally(forWidth: unnamedThreshold - 1, allowsTitle: false))
        XCTAssertTrue(PipMetrics.rowsScrollHorizontally(forWidth: unnamedThreshold, allowsTitle: false))
    }

    /// Owner 2026-10-28: "there should not be 5-hour and 7-day since already
    /// says 5h and 7d".  A label that only repeats the caption is dropped; a
    /// label that names something the caption cannot is kept.
    func testARedundantWindowLabelIsDroppedButANameIsKept() {
        XCTAssertTrue(detailLabelRedundant(caption: "5h", label: "5-hour"))
        XCTAssertTrue(detailLabelRedundant(caption: "7d", label: "7-day"))
        XCTAssertTrue(detailLabelRedundant(caption: "5h", label: "5h"))
        XCTAssertTrue(detailLabelRedundant(caption: "5h", label: ""))
        XCTAssertFalse(detailLabelRedundant(caption: "5h", label: "Sonnet"))
        XCTAssertFalse(detailLabelRedundant(caption: "7d", label: "weekly"))
        XCTAssertFalse(detailLabelRedundant(caption: "Quota", label: "Included plan"))
    }

    /// A label that merely starts with the caption's number is not a repeat of
    /// the caption.  "5 GB bonus" beside a "5h" caption names something the
    /// caption cannot, so it stays (review finding, 2026-10-28).
    func testALabelThatOnlySharesTheCaptionDigitsIsKept() {
        XCTAssertFalse(detailLabelRedundant(caption: "5h", label: "5 GB bonus"))
        XCTAssertFalse(detailLabelRedundant(caption: "1m", label: "1M tokens"))
        XCTAssertFalse(detailLabelRedundant(caption: "5h", label: "5-hour reset"))
        XCTAssertTrue(detailLabelRedundant(caption: "5h", label: "5 hour"))
        XCTAssertTrue(detailLabelRedundant(caption: "5h", label: "5h"))
        XCTAssertTrue(detailLabelRedundant(caption: "7d", label: "7-day"))
    }

    /// The percentage column has to hold "100%" at 10pt bold monospaced: the
    /// percentage is a fixed-size text, so a column narrower than the text
    /// clips its last digit (review finding, 2026-10-28).
    func testThePercentColumnHoldsOneHundredPercent() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let width = ("100%" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(width, PipMetrics.percentWidth,
                                 "the percent column must hold the widest percentage")
    }

    /// The words beside a capped row's extra balance have to still read at the
    /// narrowest width they are allowed (review finding, 2026-10-28).
    func testTheExtraBalanceWordsStillReadAtTheirSmallest() {
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let width = ("extra" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertLessThanOrEqual(width * 0.7, PipMetrics.extraBalanceTextMinWidth,
                                 "the words must still read at 70% of their full width")
    }

    /// One line of the expanded detail has to fit the smallest panel the owner
    /// can drag the HUD to, and the countdown gives way there (review finding,
    /// 2026-10-28).
    func testTheDetailLineFitsTheSmallestPanel() {
        let smallest = PipMetrics.minWidth - PipMetrics.padding * 2
        XCTAssertLessThanOrEqual(PipMetrics.detailRowMinWidth, smallest,
                                 "the narrowest detail line must fit the smallest panel")
        XCTAssertGreaterThan(PipMetrics.detailRowMinWidthWithCountdown, smallest,
                             "the countdown cannot fit the smallest panel, so it is the first thing to go")
        XCTAssertEqual(PipMetrics.detailRowMinWidthWithCountdown,
                       PipMetrics.detailRowMinWidth + PipMetrics.meterSpacing + PipMetrics.countdownWidth)
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
        XCTAssertEqual(PipMetrics.detail(forWidth: fit.width, meterCount: 1), .full)
    }

    func testFullProviderNamesFitWithoutTruncation() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for title in ["Antigravity · Third-Party", "Antigravity · Gemini", "Muse Assist", "Muse Code", "MiniMax", "OpenCode"] {
            XCTAssertLessThanOrEqual((title as NSString).size(withAttributes: [.font: font]).width, PipMetrics.titleWidth)
        }
        let boundary = PipMetrics.padding * 2 + PipMetrics.fullMinWidth
        XCTAssertTrue(PipMetrics.detail(forWidth: boundary).showsTitle)
        XCTAssertFalse(PipMetrics.detail(forWidth: boundary - 1).showsTitle)
        XCTAssertTrue(PipMetrics.detail(forWidth: boundary - 1).showsProviderLogo)
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