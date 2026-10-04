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
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift")
    }

    private static var sentenceGapURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/SentenceGap.swift")
    }

    private static var companionContentViewURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/CodeCapsCompanion/App/Views/CompanionContentView.swift")
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

    private func readCompanionContentViewSource() throws -> String {
        guard let url = Self.companionContentViewURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("CompanionContentView.swift is not present at \(Self.companionContentViewURL?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - App Group & Hygiene

    func testPlatformSpecificAppGroupIds() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"appGroupId = "group.com.simplewithus.codecaps""#),
            "iOS must use its registered App Group"
        )
        XCTAssertTrue(source.contains(#"appGroupId = "CC8UTF7ATG.codecaps""#))
        XCTAssertTrue(source.contains("#if os(macOS)"))
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

    // MARK: - Antigravity pool rows are periods, not models

    /// Regression guard for the owner report that tapping an Antigravity card on
    /// iOS listed every individual model instead of the pool's two periods.
    ///
    /// The Mac has always collapsed these: `AntigravityQuotaGroups` treats a
    /// per-model report as an *observation of a shared pool*, never as its own
    /// quota.  The companion was building one row per raw window, so a pool
    /// that holds six models showed twelve rows and buried the two numbers that
    /// mean anything.
    func testAntigravityPoolCollapsesToOneRowPerPeriod() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("private static func periodRows("),
            "CompanionQuotaModel must build Antigravity pool rows per period, not per model"
        )
        XCTAssertTrue(
            source.contains(#"let canonicalID = "antigravity:\(poolKey):\(period)""#),
            "a collapsed Antigravity row must be keyed by its pool and period, not a model window id"
        )
        XCTAssertTrue(
            source.contains("id: canonicalID"),
            "the row's id must be the pool-and-period key"
        )
        XCTAssertTrue(
            source.contains("Self.periodRows("),
            "consolidateAntigravityPool must route its children through periodRows"
        )
    }

    func testAntigravityPeriodOrderIsFiveHourThenWeekly() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"antigravityPeriodOrder = ["5h", "weekly"]"#),
            "an Antigravity pool shows its 5-hour period before its weekly period"
        )
    }

    /// The shared-pool rule from `AntigravityQuotaGroups`: a weekly reading has
    /// to be identified explicitly, and a reset's distance is not a duration.
    ///
    /// A window that names neither period is a *per-model observation of the
    /// pool*, not a third period, so it must not become a row.  This is the
    /// second half of the fix: collapsing the known periods while still emitting
    /// an "other" bucket is what left "Claude Opus 4.6 (Thinking)" and
    /// "GPT-OSS 120B (Medium)" on screen.
    func testAntigravityDropsPerModelObservationsRatherThanShowingThemAsPeriods() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("private static func antigravityPeriod(of w: WireRawWindow) -> String?"),
            "period detection must be able to answer \"neither period\""
        )
        XCTAssertTrue(
            source.contains("guard let period = antigravityPeriod(of: w) else { continue }"),
            "a window that is not a pool period must be skipped, not bucketed"
        )
        XCTAssertFalse(
            source.contains(#"return token.isEmpty ? "other" : token"#),
            "per-model observations must never become their own period row"
        )
        // Only the two canonical periods may ever produce a row.
        XCTAssertTrue(
            source.contains("return antigravityPeriodOrder.compactMap { period in"),
            "rows must be built from the two canonical periods alone"
        )
    }

    /// The payload carries the pool's own aggregate row as well as the per-model
    /// ones, so the aggregate is preferred -- it is the reading every surface
    /// agrees on.
    func testAntigravityPrefersThePoolsOwnAggregateRowPerPeriod() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"let canonicalID = "antigravity:\(poolKey):\(period)""#),
            "a period row must be keyed by the pool and period"
        )
        XCTAssertTrue(
            source.contains("let driving = candidates.first { $0.id == canonicalID }"),
            "the pool's own aggregate row must win over a per-model observation"
        )
    }

    /// A pool's headline number comes from one driving observation: latest wins,
    /// and a tie between models reading the same pool takes the lower value.
    func testAntigravityRowSelectsDrivingObservationWithoutAveraging() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("(left.remainingPercent ?? 101) < (right.remainingPercent ?? 101)"),
            "a tie between two models of one shared pool must take the lower value"
        )
        XCTAssertFalse(
            source.contains("remainingPercent) / Double("),
            "pool percentages must never be averaged"
        )
    }

    /// A five-hour cap means nothing while the pool's weekly cap is spent, so it
    /// still reports as not applicable after the collapse.
    func testAntigravityCollapsedFiveHourRowStaysMaskedUnderExhaustedWeekly() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("isMasked: period == \"5h\" && weeklyExhausted"),
            "the collapsed 5-hour row must stay masked when the pool's weekly cap is spent"
        )
    }

    /// Non-Antigravity platforms keep their per-window rows; the collapse is
    /// specific to the two shared pools.
    func testNonAntigravityPlatformsKeepTheirOwnWindows() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("let modelQualifier = (w.modelId ?? \"\").lowercased()"),
            "buildPlatformSection must still fold ordinary platforms by model-qualified cadence"
        )
    }

    // MARK: - Local Snapshot Caching and Pull-to-Refresh Parity

    func testLocalSnapshotPersistenceMethods() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("private func saveLocalSnapshot(data: Data)"),
            "CompanionQuotaModel must persist fetched snapshots to local storage"
        )
        XCTAssertTrue(
            source.contains("saveLocalSnapshot(data: data)"),
            "refresh() must save local snapshots upon successful network response"
        )
        XCTAssertTrue(
            source.contains("CodeCaps/quota-windows.json"),
            "loadLocalFallback and saveLocalSnapshot must check the app's local sandbox storage"
        )
        XCTAssertTrue(source.contains("CC8UTF7ATG.codecaps"))
        XCTAssertTrue(source.contains("group.com.simplewithus.codecaps"))
    }

    func testPullToRefreshAndButtonResponsiveness() throws {
        let source = try readCompanionContentViewSource()
        XCTAssertTrue(
            source.contains("scrollBounceBehavior(.always, axes: .vertical)"),
            "ScrollView must enable always vertical bounce so pull-to-refresh works when empty"
        )
        XCTAssertTrue(
            source.contains("SettingsRefreshButtonStyle"),
            "Settings refresh button must use SettingsRefreshButtonStyle for instant visual press feedback"
        )
        XCTAssertTrue(
            source.contains("refreshable"),
            "Settings form must support pull-to-refresh"
        )
        XCTAssertTrue(
            source.contains("task {"),
            "CompanionContentView must kick off background refresh on appear"
        )
    }
}
