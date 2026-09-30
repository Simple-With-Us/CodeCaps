import XCTest
@testable import QuotaCore

final class ResetAlarmMessageTests: XCTestCase {
    private func event(_ label: String, period: TimeInterval?, reason: ResetAlarmEvent.Reason) -> ResetAlarmEvent {
        ResetAlarmEvent(scope: "local", providerId: "anthropic", providerTitle: "Claude", windowId: label,
                        windowLabel: label, periodSeconds: period, endedPeriodResetAt: nil,
                        remainingPercent: 100, reason: reason)
    }

    func testTheLargestWindowAnnouncesTheNewPeriod() {
        let content = ResetAlarmMessage.content(for: [event("7d", period: 7 * 86_400, reason: .newPeriod)])
        XCTAssertEqual(content.title, "Quota Reset: Claude")
        XCTAssertEqual(content.body, "The 7d window reset." + sentenceGap + "A new week of quota is available.")
    }

    func testANearCapResetSaysHowCloseItGot() {
        let capped = ResetAlarmMessage.content(for: [event("5h", period: 5 * 3_600, reason: .nearCap(minimumRemaining: 0))])
        XCTAssertEqual(capped.body, "The 5h window reset after hitting its cap." + sentenceGap + "Ready to use again.")
        let close = ResetAlarmMessage.content(for: [event("5h", period: 5 * 3_600, reason: .nearCap(minimumRemaining: 12))])
        XCTAssertEqual(close.body, "The 5h window reset after reaching 12% remaining." + sentenceGap + "Ready to use again.")
    }

    func testTwoWindowsAreNamedTogetherWithTheLargestFirst() {
        let content = ResetAlarmMessage.content(for: [
            event("7d", period: 7 * 86_400, reason: .newPeriod),
            event("5h", period: 5 * 3_600, reason: .nearCap(minimumRemaining: 4)),
        ])
        XCTAssertEqual(content.windowLabels, ["7d", "5h"])
        XCTAssertEqual(content.body, "The 7d and 5h windows reset." + sentenceGap + "A new week of quota is available.")
    }

    func testAMonthlyWindowAnnouncesAMonth() {
        let content = ResetAlarmMessage.content(for: [event("1m", period: 30 * 86_400, reason: .newPeriod)])
        XCTAssertTrue(content.body.hasSuffix("A new month of quota is available."))
    }
}
