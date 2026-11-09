import XCTest
@testable import QuotaCore

/// The card headline is the plan's number, not any meter's: a scoped pool
/// allowance (a code-review or per-model bucket) is a real reading, but the
/// cap rule skips it, so counting it made the headline say 0% under a card
/// the cap rule did not call spent (CC-214).
final class CardHeadlineScopedTests: XCTestCase {
    func testAScopedAllowanceStaysOutOfTheHeadline() {
        let readings = [
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: nil),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, isScopedAllowance: true, remainingPercent: 0),
        ]
        XCTAssertNil(CardHeadline.percent(readings),
                     "a spent scoped bucket beside no plan reading must not headline 0%")
    }

    func testAScopedAllowanceDoesNotLowerTheHeadline() {
        let readings = [
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 96),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, isScopedAllowance: true, remainingPercent: 41),
        ]
        XCTAssertEqual(CardHeadline.percent(readings), 96,
                       "the headline is the plan's lowest honest reading, not the scoped bucket's")
    }

    func testMaskedAndExtraRulesStillHold() {
        let masked = [
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: true, remainingPercent: 3),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 51),
        ]
        XCTAssertEqual(CardHeadline.percent(masked), 51)
        let extra = [
            CardHeadline.Reading(isMuseAssistExtra: true, isMasked: false, remainingPercent: 81),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 63),
        ]
        XCTAssertEqual(CardHeadline.percent(extra), 81,
                       "the Muse Assist extra meter still headlines when it has room")
    }
}
