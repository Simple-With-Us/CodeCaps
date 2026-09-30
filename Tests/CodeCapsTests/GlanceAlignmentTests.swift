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

    /// The first x, in points, at or right of `from` where a pixel satisfies `test`.
    private func firstX(in rep: NSBitmapImageRep, from: CGFloat, where test: (NSColor) -> Bool) -> CGFloat? {
        let scale = CGFloat(rep.pixelsWide) / Metrics.glanceWidth
        for x in Int(from * scale)..<rep.pixelsWide {
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
        let cursor = section(GlanceFixtures.localWindows.filter { $0.providerKey == "cursor" })
        let barRow = try rowImage(cursor, issue: nil)
        // The used share of Cursor's bar is red, and nothing else in the row is.
        let barX = try XCTUnwrap(firstX(in: barRow, from: columnStart) { $0.redComponent > 0.6 && $0.greenComponent < 0.4 })

        let claude = DisplaySection.rows(for: QuotaPlatformSection(
            providerKey: "anthropic", providerLabel: "Claude", via: nil, expected: true, windows: []), now: now)[0]
        let statusRow = try rowImage(claude, issue: ClaudeLoginState.signedOut.issue)
        let textX = try XCTUnwrap(firstX(in: statusRow, from: columnStart - 2) {
            abs($0.redComponent - 0.96) > 0.2 || abs($0.greenComponent - 0.97) > 0.2
        })

        XCTAssertEqual(textX, barX, accuracy: 3, "\"not signed in\" starts where Cursor's bar starts")
        XCTAssertEqual(barX - columnStart, Metrics.glanceMeterBarInset, accuracy: 3,
                       "the bar sits one caption column in from the start of the meter")
    }

    func testTheBarInsetIsTheCaptionColumnAndItsGap() {
        XCTAssertEqual(Metrics.glanceMeterBarInset, Metrics.glanceMeterCaptionWidth + Metrics.glanceMeterGap)
        XCTAssertGreaterThan(Metrics.glanceMeterBarInset, Metrics.glanceMeterCaptionWidth,
                             "past the caption, not at its edge")
    }
}
