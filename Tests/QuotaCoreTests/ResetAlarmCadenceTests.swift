import XCTest
@testable import QuotaCore

/// The iOS companion has only a wire window's token and label to go on, and the
/// reset alarm's "largest window" rule depends on getting the period right.
final class ResetAlarmCadenceTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    func testDurationTokensAreReadInEveryUnit() {
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "5h", label: ""), 5 * hour)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "168h", label: ""), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "300m", label: ""), 5 * hour)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "1w", label: ""), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "31d", label: ""), 31 * day)
    }

    func testNamedCadencesFallBackToTheLabel() {
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "5-hour window"), 5 * hour)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "weekly", label: "Weekly window"), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "7-day window"), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "Daily window"), day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "billing-cycle", label: "Included plan"), 30 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "session", label: ""), 5 * hour)
    }

    func testAMonthlyHintMakesACadenceLessPlanAMonth() {
        XCTAssertNil(ResetAlarmCadence.periodSeconds(token: nil, label: "Included plan"))
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "Included plan", monthlyHint: true), 30 * day)
    }

    func testAnUnreadableCadenceIsUnknownNotGuessed() {
        XCTAssertNil(ResetAlarmCadence.periodSeconds(token: nil, label: "Opus quota"))
        XCTAssertNil(ResetAlarmCadence.periodSeconds(token: "abc", label: ""))
        XCTAssertNil(ResetAlarmCadence.durationSeconds("0h"))
    }

    func testCaptionsMatchWhatTheOwnerReadsInGlance() {
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 5 * hour), "5h")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 7 * day), "7d")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 30 * day), "1m")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 31 * day), "1m")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 90 * 60), "90m")
    }
}
