import SwiftUI

/// Scratch host required by an XCUITest bundle.  The test drives SpringBoard
/// and does not use this UI.
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
