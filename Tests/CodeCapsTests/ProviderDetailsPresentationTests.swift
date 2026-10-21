import XCTest
import QuotaCore
@testable import CodeCaps

final class ProviderDetailsPresentationTests: XCTestCase {
    func testAutomaticPlanAndSupplementalDetailsSurviveQuotaCap() {
        var window = QuotaWindow(id: "claude:seven_day", provider: "Claude", providerKey: "anthropic",
                                 label: "Weekly", remainingPercent: 0, planName: "Max 20x",
                                 isExhausted: true, occurredAt: "2026-10-20T12:00:00Z")
        window.usageDetails = .init(accountEmail: "account@example.test", creditBalance: 0, extraUsageEnabled: false)
        let now = Date(timeIntervalSince1970: 1_792_497_600)
        let section = QuotaPlatformSection(providerKey: "anthropic", providerLabel: "Claude", expected: true,
                                           windows: [QuotaWindowSnapshot(window: window, now: now)])
        XCTAssertEqual(section.displaySubtitle(customInfo: nil), "Max 20x")
        XCTAssertEqual(section.providerDetailRows, [
            .init(label: "Detected Plan", value: "Max 20x"),
            .init(label: "Account", value: "account@example.test"),
            .init(label: "Credits", value: "0 left"),
            .init(label: "Extra Usage", value: "disabled")])
        XCTAssertEqual(section.windows.count, 1)
        XCTAssertEqual(section.windows.first?.remainingPercent, 0)
    }

    func testScopedCodexCapDoesNotCapTheSubscription() {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let base = QuotaWindow(id: "openai:primary", provider: "Codex", providerKey: "openai",
                               label: "5h", remainingPercent: 90, occurredAt: stamp)
        let scoped = QuotaWindow(id: "local-mac:openai:code-review", provider: "Codex", providerKey: "openai",
                                 label: "Code Review · 5h", remainingPercent: 0,
                                 isExhausted: true, occurredAt: stamp)
        let section = QuotaPlatformSection(providerKey: "openai", providerLabel: "Codex", expected: true,
                                           windows: [base, scoped].map { QuotaWindowSnapshot(window: $0, now: now) })
        XCTAssertTrue(scoped.isSubModelLimit)
        XCTAssertFalse(section.isAtCap)
        XCTAssertEqual(section.drivingWindow?.window.id, base.id)
    }

    func testScopedOnlyCodexPoolsDoNotDriveTheHeadline() {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        let scoped = QuotaWindow(id: "local-mac:openai:code-review", provider: "Codex", providerKey: "openai",
                                 label: "Code Review · 5h", remainingPercent: 0,
                                 isExhausted: true, occurredAt: stamp)
        let section = QuotaPlatformSection(providerKey: "openai", providerLabel: "Codex", expected: true,
                                           windows: [QuotaWindowSnapshot(window: scoped, now: now)])
        XCTAssertFalse(section.isAtCap)
        XCTAssertNil(section.drivingWindow, "a spent scoped pool must not read as the subscription at 0%")
        XCTAssertNil(section.minimumRemainingPercent)
    }

    func testExpandedCodexPoolsKeepTheirOwnLabelsAndCadences() {
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        func snapshot(_ id: String, _ label: String, _ cadence: String) -> QuotaWindowSnapshot {
            QuotaWindowSnapshot(window: QuotaWindow(id: "local-mac:openai:" + id,
                provider: "Codex", providerKey: "openai", label: label, remainingPercent: 90,
                window: cadence, occurredAt: stamp), now: now)
        }
        let windows = [snapshot("primary", "5-hour window", "5h"),
                       snapshot("secondary", "7-day window", "1w"),
                       snapshot("additional:Spark:spark:primary", "Spark · 5-hour window", "5h"),
                       snapshot("additional:Spark:spark:secondary", "Spark · 7-day window", "1w"),
                       snapshot("code-review:secondary", "Code Review · 7-day window", "1w"),
                       snapshot("additional:Shared:a", "Shared · 7-day window", "1w"),
                       snapshot("additional:Shared:b", "Shared · 7-day window", "1w")]
        let section = QuotaPlatformSection(providerKey: "openai", providerLabel: "Codex", expected: true, windows: windows)
        let row = DisplaySection(id: "openai", providerKey: "openai", title: "Codex", platformTitle: "Codex",
                                 section: section, poolKey: nil, remainingPercent: 90, resetAt: nil,
                                 maskedWindowIds: [])
        let lines = glanceExpandedLines(for: row, now: now)
        XCTAssertEqual(Set(lines.map(\.label)), ["Spark", "Code Review", "Shared"])
        XCTAssertEqual(lines.filter { $0.label == "Shared" }.count, 2)
        XCTAssertEqual(lines.first { $0.label == "Spark" }?.short?.window.window, "5h")
        XCTAssertEqual(lines.first { $0.label == "Spark" }?.long?.window.window, "1w")
        XCTAssertNil(lines.first { $0.label == "Code Review" }?.short)
    }

    func testDetectedPlanRemainsVisibleBesideSavedManualSubtitle() {
        let now = Date()
        let window = QuotaWindow(id: "primary", provider: "Codex", providerKey: "openai", label: "5h",
                                 remainingPercent: 50, planName: "prolite",
                                 occurredAt: ISO8601DateFormatter().string(from: now))
        let section = QuotaPlatformSection(providerKey: "openai", providerLabel: "Codex", expected: true,
                                           windows: [QuotaWindowSnapshot(window: window, now: now)])
        let custom = PlatformCustomInfo(customSubtitle: "Saved Manual Text")
        XCTAssertEqual(section.displaySubtitle(customInfo: custom), "Saved Manual Text")
        XCTAssertEqual(section.providerDetailRows, [.init(label: "Detected Plan", value: "prolite")])
    }

    func testAbsentDetailsDoNotInventZeroBalanceOrAccount() {
        let section = QuotaPlatformSection(providerKey: "openai", providerLabel: "Codex", expected: true, windows: [])
        XCTAssertTrue(section.providerDetailRows.isEmpty)
        XCTAssertNil(section.automaticPlanName)
    }
}
