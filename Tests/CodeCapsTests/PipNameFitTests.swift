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
}
