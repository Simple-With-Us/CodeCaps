import Foundation
import XCTest

final class CompanionAlertPersistenceTests: XCTestCase {
    /// Execute the companion's actual property in a child process: an invalid
    /// preferences value raises an Objective-C exception rather than a Swift error.
    /// The iOS model itself imports UIKit and is outside the Mac package target.
    func testAnnouncedAlertHistoryPersistsWithoutCrashing() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var announcedAlertIds: Set<String> {"))
        let end = try XCTUnwrap(source.range(of: "/// Raise each alert", range: start.upperBound..<source.endIndex))
        let property = String(source[start.lowerBound..<end.lowerBound])
            .replacingOccurrences(of: "private var", with: "var")
            .replacingOccurrences(of: "UserDefaults.standard", with: "defaults")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("AlertPersistence.swift")
        try """
        import Foundation
        struct History {
            let defaults: UserDefaults
            \(property)
        }
        let suite = "CodeCaps.AlertPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var history = History(defaults: defaults)
        precondition(history.announcedAlertIds.isEmpty)
        history.announcedAlertIds.insert("launch-alert")
        precondition(defaults.stringArray(forKey: "announcedAlertIds") == ["launch-alert"])
        history.announcedAlertIds.insert("launch-alert")
        precondition(history.announcedAlertIds.count == 1)
        let ids = Set((0..<250).map { "alert-\\($0)" })
        history.announcedAlertIds = ids
        let stored = defaults.stringArray(forKey: "announcedAlertIds")!
        precondition(stored.count == 200)
        precondition(Set(stored).isSubset(of: ids))
        precondition(PropertyListSerialization.propertyList(stored, isValidFor: .binary))
        precondition(History(defaults: defaults).announcedAlertIds == Set(stored))
        history.announcedAlertIds = []
        precondition(defaults.stringArray(forKey: "announcedAlertIds") == [])
        """.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", script.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
            "Companion alert persistence crashed or failed its round-trip checks: "
                + String(decoding: diagnostics, as: UTF8.self))
    }
}
