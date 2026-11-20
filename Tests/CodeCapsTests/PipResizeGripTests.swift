import AppKit
import XCTest
@testable import CodeCaps

/// The PiP HUD's resize corner.
///
/// The owner reported (2026-10-23) that resizing the HUD was "super hard":
/// the panel is borderless, so AppKit's own resize area is the window's
/// bottom-right corner, and the rounded surface clips that corner away.  The
/// target the owner had to hit was a sliver of the window that the visible
/// shape did not even cover, and the drag view behind the surface took the
/// click and moved the window instead of resizing it.
///
/// These tests pin the two things that make the corner work: the grab area is
/// inside the shape the owner can see, and a drag produces the frame a corner
/// drag is supposed to produce.
@MainActor
final class PipResizeGripTests: XCTestCase {

    // MARK: Where the grab area is

    /// The whole grab area has to be inside the rounded surface, or the owner
    /// is aiming at a corner the window does not draw.
    func testTheGrabAreaIsInsideTheRoundedSurface() {
        let radius = PipMetrics.cornerRadius
        let inset = PipMetrics.resizeGripInset
        // The arc's centre, measured from the window's bottom-right corner.
        let centre = radius - inset
        // The grab area's outermost corner, from the same corner.
        let grabCorner = centre
        let distance = (grabCorner * (2 as CGFloat).squareRoot())
        XCTAssertLessThanOrEqual(distance, radius,
                                 "the grab area must be inside the rounded shape, not under its clipped corner")
    }

    /// The area has to be big enough to hit.  The owner's complaint was that it
    /// was "a super tiny area", so a corner that is technically inside the
    /// shape but too small to grab is not a fix.
    func testTheGrabAreaIsBigEnoughToHit() {
        XCTAssertGreaterThanOrEqual(PipMetrics.resizeGripSize, 20,
                                    "the corner needs an area a pointer can find")
        XCTAssertGreaterThan(PipMetrics.resizeGripSize, PipMetrics.controlHitSize,
                             "the resize corner is not a close button, so it can be larger than one")
    }

    // MARK: What a drag does

    /// Dragging the corner to the right and down grows the window, and the top
    /// and left edges stay where the owner left them.
    func testDraggingTheCornerGrowsTheWindowTheWayACornerDragDoes() {
        let start = NSRect(x: 100, y: 200, width: 300, height: 120)
        let frame = PipMetrics.resizedFrame(from: start,
                                            translation: CGSize(width: 40, height: 30),
                                            edge: .bottomRight,
                                            minSize: NSSize(width: PipMetrics.minWidth, height: PipMetrics.minHeight),
                                            maxSize: NSSize(width: PipMetrics.maxWidth, height: PipMetrics.maxHeight))
        XCTAssertEqual(frame.width, 340, "the window follows the pointer to the right")
        XCTAssertEqual(frame.height, 150, "the window follows the pointer downwards")
        XCTAssertEqual(frame.minX, start.minX, "the left edge stays where the owner left it")
        XCTAssertEqual(frame.maxY, start.maxY, "the top edge stays where the owner left it")
    }

    /// The right edge alone does not move the window up or down.
    func testDraggingTheRightEdgeOnlyChangesTheWidth() {
        let start = NSRect(x: 100, y: 200, width: 300, height: 120)
        let frame = PipMetrics.resizedFrame(from: start,
                                            translation: CGSize(width: 25, height: 40),
                                            edge: .right,
                                            minSize: NSSize(width: PipMetrics.minWidth, height: PipMetrics.minHeight),
                                            maxSize: NSSize(width: PipMetrics.maxWidth, height: PipMetrics.maxHeight))
        XCTAssertEqual(frame.width, 325)
        XCTAssertEqual(frame.height, start.height, "the right edge must not change the height")
        XCTAssertEqual(frame.minY, start.minY, "the right edge must not move the window")
    }

    /// The bottom edge alone does not change the width, and the top stays put.
    func testDraggingTheBottomEdgeOnlyChangesTheHeight() {
        let start = NSRect(x: 100, y: 200, width: 300, height: 120)
        let frame = PipMetrics.resizedFrame(from: start,
                                            translation: CGSize(width: 25, height: 40),
                                            edge: .bottom,
                                            minSize: NSSize(width: PipMetrics.minWidth, height: PipMetrics.minHeight),
                                            maxSize: NSSize(width: PipMetrics.maxWidth, height: PipMetrics.maxHeight))
        XCTAssertEqual(frame.width, start.width, "the bottom edge must not change the width")
        XCTAssertEqual(frame.height, 160)
        XCTAssertEqual(frame.maxY, start.maxY, "the top edge stays where the owner left it")
    }

    /// A borderless panel enforces its own bounds on its resize area but not on
    /// a frame set from code, so the grip has to clamp the size itself.
    func testTheGripClampsThePanelToItsBounds() {
        let start = NSRect(x: 100, y: 200, width: 300, height: 120)
        let minSize = NSSize(width: PipMetrics.minWidth, height: PipMetrics.minHeight)
        let maxSize = NSSize(width: PipMetrics.maxWidth, height: PipMetrics.maxHeight)

        let huge = PipMetrics.resizedFrame(from: start,
                                           translation: CGSize(width: 9_999, height: 9_999),
                                           edge: .bottomRight,
                                           minSize: minSize, maxSize: maxSize)
        XCTAssertEqual(huge.width, maxSize.width, "the panel cannot grow past its maximum width")
        XCTAssertEqual(huge.height, maxSize.height, "the panel cannot grow past its maximum height")

        let tiny = PipMetrics.resizedFrame(from: start,
                                           translation: CGSize(width: -9_999, height: -9_999),
                                           edge: .bottomRight,
                                           minSize: minSize, maxSize: maxSize)
        XCTAssertEqual(tiny.width, minSize.width, "the panel cannot shrink past its minimum width")
        XCTAssertEqual(tiny.height, minSize.height, "the panel cannot shrink past its minimum height")
    }

    // MARK: Wiring

    /// The grip has to be in the drawn panel and the panel has to be handed to
    /// the view, or the arithmetic above is arithmetic about nothing.
    func testTheGripIsInTheDrawnPanel() throws {
        let source = try readPipWidgetSource()
        XCTAssertTrue(
            source.contains("PipResizeGrip(edge: .bottomRight"),
            "the HUD must draw the corner grip"
        )
        // The grip's own name appears twice:  where the view declares it, and
        // where the panel's body draws it.  A second mention that is not the
        // body is the declaration, so the count is the wiring.
        XCTAssertEqual(Self.gripNameOccurrences(in: source), 2,
                       "the grip must be declared once and drawn in the panel's body")
        XCTAssertTrue(
            source.contains("PipWidgetView(model: model, panel: panel)"),
            "the panel must be handed to the view, or the grip has no window to resize"
        )
        XCTAssertTrue(
            source.contains("PipWidgetView(model: model, panel: p)"),
            "the panel must be handed to the view when it is created, or the grip has no window to resize"
        )
    }

    /// How many times the grip's own name appears as a whole word, so the
    /// declaration and the drawing are told apart from the constants that
    /// share the prefix.
    private static func gripNameOccurrences(in source: String) -> Int {
        let pattern = "(?<![A-Za-z0-9_])resizeGrip(?![A-Za-z0-9_])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(source.startIndex..., in: source)
        return regex.numberOfMatches(in: source, range: range)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func readPipWidgetSource() throws -> String {
        let url = Self.repoRoot.appendingPathComponent("Sources/CodeCaps/PipWidget.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("PipWidget.swift is not present at \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
