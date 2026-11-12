import XCTest
@testable import QuotaCore

final class QuotaMeterCadenceTests: XCTestCase {
    func testFiveHourIsShortAndWeeklyIsLong() {
        XCTAssertTrue(QuotaMeterCadence.isShort(windowToken: "5h", label: "5-hour window"))
        XCTAssertFalse(QuotaMeterCadence.isShort(windowToken: "7d", label: "7-day window"))
    }

    func testMiniMaxDailyIntervalReadsShortLikeTheCompanion() {
        XCTAssertTrue(
            QuotaMeterCadence.isShort(
                windowToken: "1d",
                label: "general (interval window)",
                cadence: "1d"
            )
        )
    }

    func testSupplementaryVideoIsShortButExcludedElsewhere() {
        XCTAssertTrue(
            QuotaMeterCadence.isShort(
                windowToken: "1d",
                label: "video (1d window)",
                isSupplementaryVideoQuota: true
            )
        )
    }
}
