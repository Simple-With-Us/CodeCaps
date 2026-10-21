import XCTest
import QuotaCore
@testable import CodeCaps

final class PlanMismatchWarningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_512_000)
    private var settings: [String: PlatformCustomInfo] { ["anthropic": .init(planName: "Max 5x")] }

    private func window(id: String = "weekly", plan: String? = "Max 20x", age: TimeInterval = 0) -> QuotaWindow {
        QuotaWindow(id: id, provider: "Claude", providerKey: "anthropic", label: "Weekly",
                    planName: plan, occurredAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-age)))
    }

    func testOneWarningPerProviderPerOpenAndEverySubsequentOpen() {
        var cycle = PlanWarningCycle()
        cycle.beginOpen()
        XCTAssertEqual(cycle.warnings(windows: [window(), window(id: "session")], customInfo: settings, now: now).count, 1)
        cycle.finishPresentation()
        XCTAssertTrue(cycle.warnings(windows: [window()], customInfo: settings, now: now).isEmpty)
        cycle.beginOpen()
        XCTAssertEqual(cycle.warnings(windows: [window()], customInfo: settings, now: now).count, 1)
    }

    func testInitialMissingDetectionCanWarnWhenAsyncReadArrives() {
        var cycle = PlanWarningCycle()
        cycle.beginOpen()
        XCTAssertTrue(cycle.warnings(windows: [window(plan: nil)], customInfo: settings, now: now).isEmpty)
        XCTAssertEqual(cycle.warnings(windows: [window()], customInfo: settings, now: now).count, 1)
    }

    func testModalActivationCannotResetOrDuplicatePresentation() {
        var cycle = PlanWarningCycle()
        cycle.beginOpen()
        _ = cycle.warnings(windows: [window()], customInfo: settings, now: now)
        cycle.beginOpen()
        XCTAssertTrue(cycle.warnings(windows: [window()], customInfo: settings, now: now).isEmpty)
        cycle.finishPresentation()
        XCTAssertTrue(cycle.warnings(windows: [window()], customInfo: settings, now: now).isEmpty)
    }

    func testStaleReportsAndCorrectedSettingsDoNotWarn() {
        var cycle = PlanWarningCycle()
        cycle.beginOpen()
        XCTAssertTrue(cycle.warnings(windows: [window(age: 3_600)], customInfo: settings, now: now).isEmpty)
        XCTAssertTrue(cycle.warnings(windows: [window()], customInfo: ["anthropic": .init(planName: "Max 20x")], now: now).isEmpty)
    }

    func testTypingDoesNotInterruptButNextOpenWarns() {
        var cycle = PlanWarningCycle()
        let correct = ["anthropic": PlatformCustomInfo(planName: "Max 20x")]
        cycle.beginOpen(customInfo: correct)
        XCTAssertTrue(cycle.warnings(windows: [window()], customInfo: correct, now: now).isEmpty)
        XCTAssertTrue(cycle.warnings(windows: [window()], customInfo: settings, now: now).isEmpty)
        cycle.beginOpen(customInfo: settings)
        XCTAssertEqual(cycle.warnings(windows: [window()], customInfo: settings, now: now).count, 1)
    }

    func testFreshPlanStillWarnsWhenQuotaResetHasPassed() {
        var value = window()
        value.resetAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        var cycle = PlanWarningCycle()
        cycle.beginOpen()
        XCTAssertEqual(cycle.warnings(windows: [value], customInfo: settings, now: now).count, 1)
    }
}
