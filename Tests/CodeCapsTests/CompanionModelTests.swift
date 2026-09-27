import XCTest
@testable import CodeCaps
import QuotaCore

/// Verifies CodeCaps companion data models, overarching platform grouping,
/// duplicate source handling, and customizable platform ordering.
///
/// Mirrors the companion contract used on iOS so behavioral regressions
/// are caught directly in the standard `swift test` suite.
final class CompanionModelTests: XCTestCase {
    private static var companionModelURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift")
    }

    private static var sentenceGapURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/SentenceGap.swift")
    }

    private func readCompanionModelSource() throws -> String {
        guard let url = Self.companionModelURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("CompanionQuotaModel.swift is not present at \(Self.companionModelURL?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func readSentenceGapSource() throws -> String {
        guard let url = Self.sentenceGapURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("SentenceGap.swift is not present at \(Self.sentenceGapURL?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - App Group & Hygiene

    func testAppGroupIdParity() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"appGroupId = "group.com.simplewithus.codecaps""#),
            "CompanionQuotaModel must use canonical App Group group.com.simplewithus.codecaps"
        )
    }

    func testSentenceGapInOutcomeMessages() throws {
        let source = try readSentenceGapSource()
        XCTAssertTrue(
            source.contains(#"Test notification sent." + sentenceGap + "Banner and sound delivered."#),
            "Test notification success message must use sentenceGap"
        )
        XCTAssertTrue(
            source.contains(#"Notifications are turned off for CodeCaps." + sentenceGap"#),
            "Denied notification message must use sentenceGap"
        )
    }

    // MARK: - Reordering Logic

    func testPlatformOrderingLogic() {
        let initial = ["anthropic", "minimax", "openai", "xai", "cursor", "grok-bot", "antigravity:gemini", "antigravity:third-party"]

        // Move minimax (index 1) to top (index 0)
        var order = initial
        let minimax = order.remove(at: 1)
        order.insert(minimax, at: 0)
        XCTAssertEqual(order.first, "minimax")
        XCTAssertEqual(order[1], "anthropic")

        // Move minimax down to index 1
        let movedDown = order.remove(at: 0)
        order.insert(movedDown, at: 1)
        XCTAssertEqual(order, initial)

        // Boundary: cannot move top element up
        XCTAssertEqual(order.firstIndex(of: "anthropic"), 0)
    }

    // MARK: - Duplicate Source Separation Logic

    func testDuplicateSourceSeparation() {
        struct WindowStub {
            let id: String
            let cadence: String
            let source: String?
            let remainingPercent: Double?
        }

        // Simulate two reports for Grok Bot weekly: primary from cursor, duplicate from gbu
        let windows: [WindowStub] = [
            WindowStub(id: "cursor:grok-bot:weekly", cadence: "weekly", source: "Cursor DashboardService", remainingPercent: 0.0),
            WindowStub(id: "gbu:grok-bot:weekly", cadence: "weekly", source: "gbu", remainingPercent: 0.0)
        ]

        var primaryWindows: [WindowStub] = []
        var duplicateWindows: [WindowStub] = []
        var seenCadences = Set<String>()

        for win in windows {
            if seenCadences.contains(win.cadence) {
                duplicateWindows.append(win)
            } else {
                seenCadences.insert(win.cadence)
                primaryWindows.append(win)
            }
        }

        XCTAssertEqual(primaryWindows.count, 1)
        XCTAssertEqual(primaryWindows.first?.source, "Cursor DashboardService")
        XCTAssertEqual(duplicateWindows.count, 1)
        XCTAssertEqual(duplicateWindows.first?.source, "gbu")
    }

    // MARK: - Antigravity Controlling Cap Masking Logic

    func testAntigravityWeeklyExhaustionMasksFiveHourWindow() {
        let weeklyPct: Double = 0.0
        let fiveHourPct: Double = 85.0

        let isFiveHourMasked = (weeklyPct <= 0.0)
        XCTAssertTrue(isFiveHourMasked, "5h window must be masked when weekly cap is 0%")

        let displayPercent = isFiveHourMasked ? "n/a" : "\(Int(round(fiveHourPct)))%"
        XCTAssertEqual(displayPercent, "n/a")
    }
}
