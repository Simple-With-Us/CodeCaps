import AppKit
import XCTest
@testable import CodeCaps

/// CC-26: Settings/Console must layer above the Glance popover when elevated.
@MainActor
final class GlanceWindowLevelsTests: XCTestCase {
    func testConsoleElevatedAboveGlancePopover() {
        XCTAssertGreaterThan(
            GlanceWindowLevels.consoleAboveGlance.rawValue,
            GlanceWindowLevels.glancePopover.rawValue,
            "Settings/Console opened from Glance must not sit behind the popover"
        )
        XCTAssertGreaterThan(
            GlanceWindowLevels.glancePopover.rawValue,
            NSWindow.Level.normal.rawValue,
            "Glance popover is expected above ordinary document windows"
        )
    }
}
