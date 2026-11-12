import XCTest
@testable import CodeCaps

@MainActor
final class PipNameFitTests: XCTestCase {
    private let screenshotTitles = [
        "MiniMax", "Claude", "Codex", "Muse Code", "Muse Assist", "Cursor", "xAI"
    ]

    func testScreenshotProviderNamesStayVisibleAtCompactFlameWidths() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)
        XCTAssertLessThan(titleWidth, PipMetrics.titleWidth,
                          "the pinned names should use less than the legacy fixed title column")

        for width in [CGFloat(429), CGFloat(425)] {
            let detail = PipMetrics.detail(forWidth: width, titleWidth: titleWidth, hasFlame: true)
            XCTAssertEqual(detail, .full, "all provider names and countdowns should fit at \(width)pt")
            XCTAssertTrue(detail.showsTitle)
            XCTAssertTrue(detail.showsCountdown)
        }
    }

    func testProviderNameDropsAtExactMeasuredWidthBeforeCountdown() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)
        let fullRowWidth = PipMetrics.rowWidth(for: .full, titleWidth: titleWidth)
        let boundary = PipMetrics.padding * 2 + fullRowWidth

        let atBoundary = PipMetrics.detail(forWidth: boundary, titleWidth: titleWidth)
        XCTAssertEqual(atBoundary, .full)
        XCTAssertTrue(atBoundary.showsTitle)
        XCTAssertTrue(atBoundary.showsCountdown)

        let onePointBelow = PipMetrics.detail(forWidth: boundary - 1, titleWidth: titleWidth)
        XCTAssertEqual(onePointBelow, .logoWithFullCountdown)
        XCTAssertFalse(onePointBelow.showsTitle)
        XCTAssertTrue(onePointBelow.showsProviderLogo)
        XCTAssertTrue(onePointBelow.showsCountdown,
                      "the provider name must drop before its countdown")
    }

    func testFlameMovesTheFullNameBoundaryByItsRenderedWidth() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)
        let withoutFlame = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .full, titleWidth: titleWidth)
        let withFlame = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .full, hasFlame: true, titleWidth: titleWidth)

        XCTAssertEqual(withFlame - withoutFlame, PipMetrics.flameWidth)
        XCTAssertEqual(PipMetrics.detail(forWidth: withoutFlame, titleWidth: titleWidth), .full)
        XCTAssertEqual(PipMetrics.detail(forWidth: withFlame - 1, titleWidth: titleWidth), .full,
                       "the row still fits when the flame is absent")
        XCTAssertEqual(PipMetrics.detail(forWidth: withFlame, titleWidth: titleWidth, hasFlame: true), .full)
        XCTAssertEqual(PipMetrics.detail(forWidth: withFlame - 1, titleWidth: titleWidth, hasFlame: true),
                       .logoWithFullCountdown)
    }

    func testTitleWidthCapsLongNamesAndKeepsEmptyListFallback() {
        XCTAssertEqual(PipMetrics.titleColumnWidth(for: []), PipMetrics.titleWidth)
        XCTAssertEqual(PipMetrics.titleColumnWidth(for: [String(repeating: "W", count: 200)]),
                       PipMetrics.titleWidth)
    }

    func testResponsiveDetailAndHorizontalThresholdStayMonotonicForMeasuredTitles() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)
        var lastRawValue = Int.max

        for width in stride(from: PipMetrics.minWidth, through: PipMetrics.maxWidth, by: 1) {
            let detail = PipMetrics.detail(forWidth: width, titleWidth: titleWidth, hasFlame: true)
            XCTAssertLessThanOrEqual(detail.rawValue, lastRawValue,
                                     "wider PiP windows must not lose detail at \(width)pt")
            lastRawValue = detail.rawValue
        }

        let horizontalBoundary = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .full, hasFlame: true, titleWidth: titleWidth)
            + PipMetrics.horizontalPeek
        XCTAssertFalse(PipMetrics.rowsScrollHorizontally(
            forWidth: horizontalBoundary - 1, titleWidth: titleWidth, hasFlame: true))
        XCTAssertTrue(PipMetrics.rowsScrollHorizontally(
            forWidth: horizontalBoundary, titleWidth: titleWidth, hasFlame: true))
        for width in stride(from: horizontalBoundary, through: PipMetrics.maxWidth, by: 7) {
            XCTAssertTrue(PipMetrics.rowsScrollHorizontally(
                forWidth: width, titleWidth: titleWidth, hasFlame: true),
                "horizontal rows must stay enabled beyond the full-row-plus-peek boundary")
        }
    }

    func testTwoMeterSingleProviderBudgetIncludesExpandedCadenceAtFullBoundary() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)
        let compactRowWidth = PipMetrics.rowWidth(
            for: .full, titleWidth: titleWidth, meterCount: 2, expandedCadence: false)
        let expandedRowWidth = PipMetrics.rowWidth(
            for: .full, titleWidth: titleWidth, meterCount: 2, expandedCadence: true)
        let compactBoundary = PipMetrics.padding * 2 + compactRowWidth
        let expandedBoundary = PipMetrics.padding * 2 + expandedRowWidth

        XCTAssertEqual(expandedRowWidth - compactRowWidth, 44,
                       "two expanded 40pt cadence captions reserve 22pt each")
        XCTAssertEqual(PipMetrics.detail(
            forWidth: compactBoundary, titleWidth: titleWidth, meterCount: 2,
            expandedCadence: false), .full)

        let expandedAtCompactBoundary = PipMetrics.detail(
            forWidth: compactBoundary, titleWidth: titleWidth, meterCount: 2,
            expandedCadence: true)
        XCTAssertEqual(expandedAtCompactBoundary, .logoWithFullCountdown)
        XCTAssertFalse(expandedAtCompactBoundary.showsTitle)
        XCTAssertTrue(expandedAtCompactBoundary.showsCountdown)
        XCTAssertEqual(PipMetrics.detail(
            forWidth: expandedBoundary, titleWidth: titleWidth, meterCount: 2,
            expandedCadence: true), .full)
        XCTAssertEqual(PipMetrics.detail(
            forWidth: expandedBoundary - 1, titleWidth: titleWidth, meterCount: 2,
            expandedCadence: true), .logoWithFullCountdown)
    }

    func testSingleMeterProviderKeepsItsNameBelowTheDualMeterBoundary() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)
        let singleMeterBoundary = PipMetrics.padding * 2 + PipMetrics.rowWidth(
            for: .full, titleWidth: titleWidth, meterCount: 1, expandedCadence: true)
        let dualMeterBoundary = PipMetrics.padding * 2 + PipMetrics.rowWidth(
            for: .full, titleWidth: titleWidth, meterCount: 2, expandedCadence: true)

        XCTAssertLessThan(singleMeterBoundary, dualMeterBoundary)
        XCTAssertEqual(PipMetrics.detail(
            forWidth: singleMeterBoundary, titleWidth: titleWidth, meterCount: 1,
            expandedCadence: true), .full)
        XCTAssertEqual(PipMetrics.detail(
            forWidth: dualMeterBoundary - 1, titleWidth: titleWidth, meterCount: 1,
            expandedCadence: true), .full,
            "one pinned meter should keep its provider name below the two-meter threshold")
        XCTAssertFalse(PipMetrics.detail(
            forWidth: singleMeterBoundary - 1, titleWidth: titleWidth, meterCount: 1,
            expandedCadence: true).showsTitle)
    }

    func testSingleProviderShortensCadenceBeforeHidingItsName() {
        let titleWidth = PipMetrics.titleColumnWidth(for: ["MiniMax"])
        let compactBoundary = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .full, titleWidth: titleWidth, meterCount: 2)
        let expandedBoundary = PipMetrics.padding * 2
            + PipMetrics.rowWidth(for: .full, titleWidth: titleWidth, meterCount: 2, expandedCadence: true)

        for width in [compactBoundary, expandedBoundary - 1] {
            let expanded = PipMetrics.expandedCadenceFits(
                forWidth: width, titleWidth: titleWidth, hasFlame: false, meterCount: 2)
            XCTAssertFalse(expanded)
            XCTAssertTrue(PipMetrics.detail(forWidth: width, titleWidth: titleWidth,
                meterCount: 2, expandedCadence: expanded).showsTitle)
        }
        XCTAssertTrue(PipMetrics.expandedCadenceFits(
            forWidth: expandedBoundary, titleWidth: titleWidth, hasFlame: false, meterCount: 2))
        XCTAssertFalse(PipMetrics.detail(forWidth: compactBoundary - 1, titleWidth: titleWidth,
            meterCount: 2).showsTitle)
    }

    func testMeterCountClampsToDisplayedRangeAndHorizontalBudgetUsesSameInputs() {
        let titleWidth = PipMetrics.titleColumnWidth(for: screenshotTitles)

        XCTAssertEqual(
            PipMetrics.rowWidth(for: .full, titleWidth: titleWidth, meterCount: 0),
            PipMetrics.rowWidth(for: .full, titleWidth: titleWidth, meterCount: 1))
        XCTAssertEqual(
            PipMetrics.rowWidth(for: .full, titleWidth: titleWidth, meterCount: 3),
            PipMetrics.rowWidth(for: .full, titleWidth: titleWidth, meterCount: 2))
        XCTAssertEqual(
            PipMetrics.rowWidth(for: .logoSingleMeter, titleWidth: titleWidth, meterCount: 3),
            PipMetrics.rowWidth(for: .logoSingleMeter, titleWidth: titleWidth, meterCount: 1))

        let rowWidth = PipMetrics.rowWidth(
            for: .full, hasFlame: true, titleWidth: titleWidth, meterCount: 1,
            expandedCadence: true)
        let horizontalBoundary = PipMetrics.padding * 2 + rowWidth + PipMetrics.horizontalPeek
        XCTAssertFalse(PipMetrics.rowsScrollHorizontally(
            forWidth: horizontalBoundary - 1, titleWidth: titleWidth, hasFlame: true,
            meterCount: 1, expandedCadence: true))
        XCTAssertTrue(PipMetrics.rowsScrollHorizontally(
            forWidth: horizontalBoundary, titleWidth: titleWidth, hasFlame: true,
            meterCount: 1, expandedCadence: true))
    }

    func testSingleProviderCadenceChoiceKeepsResizingMonotonic() {
        let titleWidth = PipMetrics.titleColumnWidth(for: ["MiniMax"])
        for count in [1, 2] {
            var previousDetail = Int.max
            var wasHorizontal = false
            for width in stride(from: PipMetrics.minWidth, through: PipMetrics.maxWidth, by: 1) {
                let expanded = PipMetrics.expandedCadenceFits(
                    forWidth: width, titleWidth: titleWidth, hasFlame: true, meterCount: count)
                let detail = PipMetrics.detail(forWidth: width, titleWidth: titleWidth,
                    hasFlame: true, meterCount: count, expandedCadence: expanded)
                let horizontal = PipMetrics.rowsScrollHorizontally(forWidth: width, titleWidth: titleWidth,
                    hasFlame: true, meterCount: count, expandedCadence: expanded)
                XCTAssertLessThanOrEqual(detail.rawValue, previousDetail)
                if wasHorizontal { XCTAssertTrue(horizontal) }
                previousDetail = detail.rawValue
                wasHorizontal = horizontal
            }
        }
    }
}
