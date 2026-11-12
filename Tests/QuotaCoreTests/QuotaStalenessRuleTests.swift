import Foundation
import XCTest
@testable import QuotaCore

/// The one rule that decides whether a reading is old enough that a surface
/// must date it, and the wording it uses when it does.
///
/// The Mac's popover, the Mac's PiP, the phone and the widgets each had their
/// own answer, and the Mac's answer for Muse Code was "no marker at all", so
/// the phone and the Mac told the owner different things about one reading.
final class QuotaStalenessRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAFreshReadingHasNoCue() {
        XCTAssertNil(QuotaStalenessRule.cue(observedAt: now.addingTimeInterval(-60),
                                            resetAt: now.addingTimeInterval(3_600),
                                            now: now))
    }

    func testAStaleReadingIsDated() {
        let cue = QuotaStalenessRule.cue(observedAt: now.addingTimeInterval(-3 * 3_600),
                                         resetAt: now.addingTimeInterval(3_600),
                                         now: now)
        XCTAssertNotNil(cue, "a reading older than the freshness threshold says so")
        XCTAssertTrue(cue?.hasPrefix("stale") == true,
                      "the cue names the staleness: \(cue ?? "")")
    }

    func testAPeriodThatHasEndedIsNotStale() {
        XCTAssertNil(QuotaStalenessRule.cue(observedAt: now.addingTimeInterval(-3 * 3_600),
                                            resetAt: now.addingTimeInterval(-60),
                                            now: now),
                     "a period that has ended is the dead-copy path's business, not a stale reading")
    }

    func testAReadingTheFeedNeverDatedIsNotStale() {
        XCTAssertNil(QuotaStalenessRule.cue(observedAt: nil,
                                            resetAt: now.addingTimeInterval(3_600),
                                            now: now),
                     "an undated reading is unverified rather than stale")
    }

    func testTheCueNamesTheSameWordsEverywhere() {
        let cue = QuotaStalenessRule.cue(observedAt: now.addingTimeInterval(-3 * 3_600),
                                         resetAt: now.addingTimeInterval(3_600),
                                         now: now)
        XCTAssertEqual(cue, "stale \u{00B7} updated \(UpdatedStamp.label(now.addingTimeInterval(-3 * 3_600), now: now))")
    }
}
