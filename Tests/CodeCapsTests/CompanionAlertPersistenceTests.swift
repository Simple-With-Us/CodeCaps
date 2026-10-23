import Foundation
import XCTest
@testable import QuotaCore

final class CompanionAlertPersistenceTests: XCTestCase {
    /// Execute the companion's actual property in a child process: an invalid
    /// preferences value raises an Objective-C exception rather than a Swift error.
    /// The iOS model itself imports UIKit and is outside the Mac package target.
    func testAnnouncedAlertHistoryPersistsWithoutCrashing() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("CompanionQuotaModel.swift is not present at \(sourceURL.path)")
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var announcedAlertIds: Set<String> {"),
            "CompanionQuotaModel.announcedAlertIds changed; update the property extraction")
        let end = try XCTUnwrap(source.range(of: "/// Raise each alert", range: start.upperBound..<source.endIndex),
            "The marker after announcedAlertIds changed; update the property extraction")
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
        precondition(History(defaults: defaults).announcedAlertIds == Set(stored))
        history.announcedAlertIds = []
        precondition(defaults.stringArray(forKey: "announcedAlertIds") == [])
        """.write(to: script, atomically: true, encoding: .utf8)

        // Reuse the bounded runner's null stdin, output cap, deadline and kill
        // escalation so a wedged interpreter cannot stall the package suite.
        _ = try await BoundedQuotaProcess().run(path: "/usr/bin/xcrun",
            arguments: ["swift", script.path], home: FileManager.default.homeDirectoryForCurrentUser,
            timeout: 120)
    }
}
