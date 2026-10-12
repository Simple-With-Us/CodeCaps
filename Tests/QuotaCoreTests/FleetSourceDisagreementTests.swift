import XCTest
@testable import QuotaCore

final class FleetSourceDisagreementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func minutesAgo(_ minutes: Double) -> Date {
        now.addingTimeInterval(-minutes * 60)
    }

    func testAlertRequiresBothFeedsWithinTwentyMinutesAndTenPointGap() {
        let freshPrimary = FleetSourceReading(remainingPercent: 5, reportedAt: minutesAgo(5))
        let freshDuplicate = FleetSourceReading(remainingPercent: 96, reportedAt: minutesAgo(10))
        XCTAssertTrue(
            FleetSourceDisagreement.shouldShowDisagreementAlert(
                primary: freshPrimary,
                duplicate: freshDuplicate,
                now: now
            )
        )
    }

    func testNoAlertWhenEitherFeedIsOlderThanTwentyMinutes() {
        let stale = FleetSourceReading(remainingPercent: 5, reportedAt: minutesAgo(21))
        let fresh = FleetSourceReading(remainingPercent: 96, reportedAt: minutesAgo(5))
        XCTAssertFalse(
            FleetSourceDisagreement.shouldShowDisagreementAlert(primary: stale, duplicate: fresh, now: now)
        )
        XCTAssertFalse(
            FleetSourceDisagreement.shouldShowDisagreementAlert(primary: fresh, duplicate: stale, now: now)
        )
    }

    func testNoAlertWhenGapIsUnderTenPoints() {
        let left = FleetSourceReading(remainingPercent: 50, reportedAt: minutesAgo(5))
        let right = FleetSourceReading(remainingPercent: 58, reportedAt: minutesAgo(8))
        XCTAssertFalse(
            FleetSourceDisagreement.shouldShowDisagreementAlert(primary: left, duplicate: right, now: now)
        )
    }

    func testFreshestReadingWinsOtherwise() {
        let older = FleetSourceReading(remainingPercent: 5, reportedAt: minutesAgo(40))
        let newer = FleetSourceReading(remainingPercent: 96, reportedAt: minutesAgo(2))
        XCTAssertEqual(
            FleetSourceDisagreement.freshestReading([older, newer])?.remainingPercent,
            96
        )
    }

    func testOlderPeerMarkedStaleInSourceDetail() {
        let older = FleetSourceReading(remainingPercent: 5, reportedAt: minutesAgo(40))
        let newer = FleetSourceReading(remainingPercent: 96, reportedAt: minutesAgo(2))
        let peers = [older, newer]
        XCTAssertTrue(FleetSourceDisagreement.isStaleAmongPeers(older, peers: peers))
        XCTAssertFalse(FleetSourceDisagreement.isStaleAmongPeers(newer, peers: peers))
    }

    func testAlertFreshnessWindowIsTwentyMinutes() {
        XCTAssertEqual(FleetSourceDisagreement.alertFreshnessWindow, 20 * 60)
    }

    func testFreshMacReadingWinsOverNewerMirror() {
        let observations = [
            FleetQuotaObservation(remainingPercent: 96, reportedAt: minutesAgo(1), isMacCodeCapsReading: false),
            FleetQuotaObservation(remainingPercent: 5, reportedAt: minutesAgo(4), isMacCodeCapsReading: true),
        ]
        let pick = FleetMacReading.pickCardDisplay(from: observations, now: now)
        XCTAssertEqual(pick?.chosenIndex, 1)
        XCTAssertNil(pick?.updatedLabel)
    }

    func testStaleMacFallsBackToFreshestWithUpdatedLabel() {
        let observations = [
            FleetQuotaObservation(remainingPercent: 5, reportedAt: minutesAgo(25), isMacCodeCapsReading: true),
            FleetQuotaObservation(remainingPercent: 96, reportedAt: minutesAgo(2), isMacCodeCapsReading: false),
        ]
        let pick = FleetMacReading.pickCardDisplay(from: observations, now: now)
        XCTAssertEqual(pick?.chosenIndex, 1)
        XCTAssertEqual(pick?.updatedLabel, "Updated " + FleetMacReading.updatedTimeCaption(for: minutesAgo(2)))
    }
}
