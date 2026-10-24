import Foundation
import XCTest

/// `SMAppService.status` is a synchronous XPC round trip to `smd`.  When it
/// ran in a `@State` initializer, every SwiftUI update that rebuilt the gear
/// menu parked the main thread in `mach_msg` until `smd` answered, and the
/// app-hang tracker reported the freeze as "App hanging for at least 2000
/// ms".  The read belongs on a background queue, and a `@State` initializer
/// must never call it.
final class LaunchAtLoginToggleTests: XCTestCase {
    private var source: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeCaps/QuickSettingsCommands.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testTheLaunchAtLoginStateIsNotSeededByTheBlockingServiceStatusCall() {
        XCTAssertFalse(source.isEmpty, "QuickSettingsCommands.swift was not found")
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@State") else { continue }
            XCTAssertFalse(trimmed.contains("SMAppService"),
                           "a @State initializer must not call the blocking smd round trip: \(trimmed)")
        }
    }

    func testTheRegistrationStateIsReadOnABackgroundQueue() {
        XCTAssertTrue(source.contains("DispatchQueue.global"),
                      "the registration state must be read on a background queue")
        XCTAssertTrue(source.contains("SMAppService.mainApp.status"),
                      "the registration state must still be read from the OS, never from a cached flag")
    }
}
