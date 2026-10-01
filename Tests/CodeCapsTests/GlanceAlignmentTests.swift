import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Lays a real Glance row out and looks at its pixels, because a column that
/// lines up on paper can still miss by a caption's width on screen.
///
/// Owner delta 2026-09-30, item 11: a row with no reading ("not signed in",
/// "unavailable", "login idle", "needs permission") starts its text where a
/// single bar starts — Cursor's, say — not at the far right and not at the edge
/// of the column, which is left of the caption.
@MainActor
final class GlanceAlignmentTests: XCTestCase {
    private let now = GlanceFixtures.now

    private func rowImage(_ row: DisplaySection, issue: String?) throws -> NSBitmapImageRep {
        let view = GlanceRow(row: row, now: now, issue: issue, origin: .local, markStyle: .standard)
            .background(Theme.background)
        guard let png = GlanceFixtures.png(
            of: view, size: CGSize(width: Metrics.glanceWidth, height: Metrics.glanceLocalRowHeight), dark: false),
              let rep = NSBitmapImageRep(data: png) else {
            throw XCTSkip("AppKit could not draw offscreen in this session")
        }
        return rep
    }

    /// The first x, in points, at or right of `from` where a pixel satisfies
    /// `test`.  `width` is the width, in points, the image was drawn at.
    private func firstX(in rep: NSBitmapImageRep, from: CGFloat, to end: CGFloat? = nil,
                        width: CGFloat = Metrics.glanceWidth,
                        where test: (NSColor) -> Bool) -> CGFloat? {
        let scale = CGFloat(rep.pixelsWide) / width
        for x in Int(from * scale)..<min(rep.pixelsWide, end.map { Int($0 * scale) } ?? rep.pixelsWide) {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), test(color) {
                    return CGFloat(x) / scale
                }
            }
        }
        return nil
    }

    /// Where the meter column starts: the gutter, the logo and name block, and
    /// the gap after it.
    private var columnStart: CGFloat {
        Metrics.glanceGutter + Metrics.glanceLogoWidth + Metrics.glanceLogoGap
            + Metrics.glanceRowTitleWidth + Metrics.glanceColumnGap
    }

    private func section(_ windows: [QuotaWindow]) -> DisplaySection {
        let sections = QuotaResponse(generatedAt: "", windows: windows).platformSections(now: now)
        return DisplaySection.rows(for: sections.first { !$0.windows.isEmpty }!, now: now)[0]
    }

    func testStatusTextStartsWhereASingleBarStarts() throws {
        // Measured on a TWO-window row.  A single meter starts in the same
        // first column (`testASingleMeterRowStartsInTheFirstColumn…`), so
        // Claude's first meter and Cursor's bar share one position, and that is
        // the position the status text has to line up with.
        let claude = section(GlanceFixtures.localWindows.filter { $0.providerKey == "anthropic" })
        let barRow = try rowImage(claude, issue: nil)
        // The used share of Claude's first bar is red, and nothing else in the
        // row is.
        let barX = try XCTUnwrap(firstX(in: barRow, from: columnStart) { $0.redComponent > 0.6 && $0.greenComponent < 0.4 })

        let signedOut = DisplaySection.rows(for: QuotaPlatformSection(
            providerKey: "anthropic", providerLabel: "Claude", via: nil, expected: true, windows: []), now: now)[0]
        let statusRow = try rowImage(signedOut, issue: ClaudeLoginState.signedOut.issue)
        let textX = try XCTUnwrap(firstX(in: statusRow, from: columnStart - 2) {
            abs($0.redComponent - 0.96) > 0.2 || abs($0.greenComponent - 0.97) > 0.2
        })

        XCTAssertEqual(textX, barX, accuracy: 3, "\"not signed in\" starts where a bar starts")

        // And where a single-meter row's bar starts, which is the same place.
        let cursor = section(GlanceFixtures.localWindows.filter { $0.providerKey == "cursor" })
        let cursorBarX = try XCTUnwrap(firstX(in: try rowImage(cursor, issue: nil), from: columnStart) {
            $0.redComponent > 0.6 && $0.greenComponent < 0.4
        })
        XCTAssertEqual(textX, cursorBarX, accuracy: 3, "\"not signed in\" starts where Cursor's lone bar starts")
        XCTAssertEqual(barX - columnStart, Metrics.glanceMeterBarInset, accuracy: 3,
                       "the bar sits one caption column in from the start of the meter")
    }

    /// The last x, in points, left of `before` where a pixel is not the popover
    /// background: the right edge of a meter's caption, which is trailing-aligned
    /// in its column.
    private func lastInkX(in rep: NSBitmapImageRep, from: CGFloat, before: CGFloat) -> CGFloat? {
        let scale = CGFloat(rep.pixelsWide) / Metrics.glanceWidth
        var found: CGFloat?
        for x in Int(from * scale)..<Int(before * scale) {
            for y in 0..<rep.pixelsHigh {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), isInk(color) {
                    found = CGFloat(x + 1) / scale
                    break
                }
            }
        }
        return found
    }

    /// Whether a pixel is anything but the light popover background.
    private func isInk(_ color: NSColor) -> Bool {
        abs(color.redComponent - 0.96) > 0.2 || abs(color.greenComponent - 0.97) > 0.2
    }

    private func isUsedShare(_ color: NSColor) -> Bool {
        color.redComponent > 0.6 && color.greenComponent < 0.4
    }

    /// A row with one meter puts it in the FIRST column, exactly where a
    /// two-meter row puts its first one, and leaves the second column empty.
    /// Never centred: the owner has ruled on this twice, and a centred lone bar
    /// (PR #88) read as a different grid from the rows above and below it.
    ///
    /// Measured against rendered pixels: the bar's first used-share pixel, and
    /// the caption's right edge (the caption is trailing-aligned in its
    /// column, so its left edge moves with the glyphs but its right edge does
    /// not).
    func testASingleMeterRowStartsInTheFirstColumnOfATwoMeterRow() throws {
        let twoMeter = try rowImage(
            section(GlanceFixtures.localWindows.filter { $0.providerKey == "anthropic" }), issue: nil)
        let referenceBar = try XCTUnwrap(firstX(in: twoMeter, from: columnStart, where: isUsedShare))
        let barEdge = referenceBar - Metrics.glanceMeterGap
        let referenceCaption = try XCTUnwrap(lastInkX(in: twoMeter, from: columnStart, before: barEdge))
        XCTAssertEqual(referenceBar - columnStart, Metrics.glanceMeterBarInset, accuracy: 3,
                       "the reference bar sits one caption column in from the start of the meter")

        // Cursor's "1m", Grok's "7d", and Grok Bot's "7d" (the row that drew a
        // stray second bar and is now one) are the single-meter rows.
        for provider in ["cursor", "xai", "grok-bot"] {
            let row = section(GlanceFixtures.localWindows.filter { $0.providerKey == provider })
            let pair = glanceMeterPair(for: row, now: now)
            XCTAssertNotNil(pair.short, "\(provider) has a meter")
            XCTAssertNil(pair.long, "\(provider) is a single-meter row")

            let image = try rowImage(row, issue: nil)
            let bar = try XCTUnwrap(firstX(in: image, from: columnStart, where: isUsedShare), provider)
            XCTAssertEqual(bar, referenceBar, accuracy: 2, "\(provider)'s bar starts at a two-meter row's first bar")
            let caption = try XCTUnwrap(lastInkX(in: image, from: columnStart, before: bar - Metrics.glanceMeterGap),
                                        provider)
            XCTAssertEqual(caption, referenceCaption, accuracy: 2,
                           "\(provider)'s caption ends where a two-meter row's first caption does")
            XCTAssertLessThan(caption, columnStart + Metrics.glanceMeterCaptionWidth + 1,
                              "\(provider)'s caption is inside the first column")

            // The second column is empty: nothing is drawn across its width.
            let secondColumn = columnStart + Metrics.glanceMeterWidth + Metrics.glanceMeterGroupGap
            XCTAssertNil(firstX(in: image, from: secondColumn, to: secondColumn + Metrics.glanceMeterWidth,
                                where: isInk),
                         "\(provider) leaves the second column empty")
        }
    }

    /// One line of meters drawn the way a row and every expanded line draw it.
    private func columnsImage(short: QuotaWindowSnapshot?, long: QuotaWindowSnapshot?) throws -> NSBitmapImageRep {
        let size = CGSize(width: Metrics.glanceMetersWidth, height: Metrics.glanceExpandedLineHeight)
        // Filled to the full size first, so the background covers the whole image
        // and "nothing drawn here" means the background colour, not transparency.
        let view = GlanceMeterColumns(short: short, long: long, now: now)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(Theme.background)
        guard let png = GlanceFixtures.png(of: view, size: size, dark: false),
              let rep = NSBitmapImageRep(data: png) else {
            throw XCTSkip("AppKit could not draw offscreen in this session")
        }
        return rep
    }

    /// An expanded line with one window keeps it under the column its cadence
    /// names: a lone weekly under the row's weekly meter, a lone short window
    /// under the row's short one.  A lone meter is never centred between them.
    func testALoneWindowOnAnExpandedLineSitsUnderItsOwnCadenceColumn() throws {
        let claude = section(GlanceFixtures.localWindows.filter { $0.providerKey == "anthropic" })
        let pair = glanceMeterPair(for: claude, now: now)
        let window = try XCTUnwrap(pair.short)
        let width = Metrics.glanceMetersWidth
        let secondColumn = Metrics.glanceMeterWidth + Metrics.glanceMeterGroupGap

        let both = try columnsImage(short: window, long: window)
        let firstBar = try XCTUnwrap(firstX(in: both, from: 0, width: width, where: isUsedShare))
        let secondBar = try XCTUnwrap(firstX(in: both, from: secondColumn, width: width, where: isUsedShare))
        XCTAssertEqual(firstBar, Metrics.glanceMeterBarInset, accuracy: 2)
        XCTAssertEqual(secondBar - firstBar, secondColumn, accuracy: 2, "the two columns are one meter plus the gap apart")

        let onlyShort = try columnsImage(short: window, long: nil)
        XCTAssertEqual(try XCTUnwrap(firstX(in: onlyShort, from: 0, width: width, where: isUsedShare)),
                       firstBar, accuracy: 2, "a lone short window is under the first column")
        XCTAssertNil(firstX(in: onlyShort, from: secondColumn, width: width, where: isInk),
                     "and nothing is under the second")

        let onlyLong = try columnsImage(short: nil, long: window)
        XCTAssertEqual(try XCTUnwrap(firstX(in: onlyLong, from: 0, width: width, where: isUsedShare)),
                       secondBar, accuracy: 2, "a lone long window is under the second column")
        XCTAssertNil(firstX(in: onlyLong, from: 0, to: secondColumn - 1, width: width, where: isInk),
                     "and nothing is under the first")
    }

    func testTheBarInsetIsTheCaptionColumnAndItsGap() {
        XCTAssertEqual(Metrics.glanceMeterBarInset, Metrics.glanceMeterCaptionWidth + Metrics.glanceMeterGap)
        XCTAssertGreaterThan(Metrics.glanceMeterBarInset, Metrics.glanceMeterCaptionWidth,
                             "past the caption, not at its edge")
    }
}
