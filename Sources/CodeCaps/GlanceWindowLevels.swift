import AppKit

/// Window levels for Glance and the Settings/Console window (CC-26).
///
/// The Glance popover uses AppKit's pop-up menu level.  When Settings or
/// Console opens while Glance is visible, the console is raised one step above
/// so it is not trapped behind the popover.
enum GlanceWindowLevels {
    static var glancePopover: NSWindow.Level {
        NSWindow.Level(Int(CGWindowLevelForKey(.popUpMenuWindow)))
    }

    static var consoleAboveGlance: NSWindow.Level {
        NSWindow.Level(glancePopover.rawValue + 1)
    }
}
