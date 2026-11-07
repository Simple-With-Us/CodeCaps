import Foundation
import XCTest
@testable import QuotaCore

/// The rule that picks a provider's two meters, shared by the Mac's Glance
/// panel, the iOS companion and the widgets.
final class QuotaWindowPairingTests: XCTestCase {

    private func candidate(
        _ id: String,
        percent: Double?,
        isShort: Bool,
        excluded: Bool = false,
        resetAt: Date? = nil
    ) -> QuotaWindowPairing.MeterCandidate {
        QuotaWindowPairing.MeterCandidate(
            id: id, remainingPercent: percent, resetAt: resetAt,
            isShort: isShort, isExcluded: excluded)
    }

    /// The bug the owner reported:  MiniMax's video allowance is a one-day
    /// window, so a surface that picked its second meter by "the first window
    /// that is not short" drew the video allowance as the weekly meter and
    /// pushed the real weekly reading out of sight.
    func testTheVideoAllowanceNeverTakesTheWeeklySlot() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("5h", percent: 99, isShort: true),
            candidate("video", percent: 100, isShort: false, excluded: true),
            candidate("7d", percent: 54, isShort: false),
        ])
        XCTAssertEqual(pair.short?.id, "5h")
        XCTAssertEqual(pair.long?.id, "7d")
    }

    /// Each side takes the window nearest to its cap, so the two meters are
    /// the ones the owner routes on.
    func testEachSideTakesTheWindowNearestToItsCap() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("5h-healthy", percent: 90, isShort: true),
            candidate("5h-tight", percent: 12, isShort: true),
            candidate("7d", percent: 54, isShort: false),
        ])
        XCTAssertEqual(pair.short?.id, "5h-tight")
        XCTAssertEqual(pair.long?.id, "7d")
    }

    /// A provider with one cadence still fills the first slot, and the second
    /// slot stays empty rather than repeating the first.
    func testOneWindowFillsTheFirstSlotOnly() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("weekly", percent: 35, isShort: false),
        ])
        XCTAssertEqual(pair.short?.id, "weekly")
        XCTAssertNil(pair.long)
    }

    /// A second source's report of the meter the first slot already shows is
    /// not a second meter.
    func testTheSecondSlotNeverRepeatsTheFirst() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("weekly-a", percent: 35, isShort: false),
            candidate("weekly-b", percent: 36, isShort: false),
        ]) { lhs, rhs in
            lhs.id == "weekly-b" && rhs.id == "weekly-a"
        }
        XCTAssertEqual(pair.short?.id, "weekly-a")
        XCTAssertNil(pair.long)
    }

    /// A window that reports no percentage never displaces one that does.
    func testAWindowWithoutAReadingNeverDisplacesOneWithAReading() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("plan", percent: nil, isShort: true),
            candidate("5h", percent: 96, isShort: true),
            candidate("7d", percent: 53, isShort: false),
        ])
        XCTAssertEqual(pair.short?.id, "5h")
        XCTAssertEqual(pair.long?.id, "7d")
    }

    /// A window with neither a percentage nor a reset says nothing, so it must
    /// not fill the second slot with a dummy bar.
    func testAnEmptyWindowDoesNotFillTheSecondSlot() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("5h", percent: 96, isShort: true),
            candidate("nothing", percent: nil, isShort: false),
        ])
        XCTAssertEqual(pair.short?.id, "5h")
        XCTAssertNil(pair.long)
    }

    /// The owner's live complaint, kept as a test:  "how does MM have a 1d
    /// quota bar?"
    ///
    /// These are MiniMax's rows as the server held them on 2026-11-04:  the
    /// five-hour window at 85, the coding plan's four-hour view of the same
    /// allowance at 86, the weekly window at 52, the video allowance's weekly
    /// window at 100, and the video allowance itself at 100 on a one-day
    /// window.  The two video windows are the supplementary video allowance,
    /// which the shared rule excludes, and the row the owner routes on is the
    /// five-hour and the weekly window.
    func testTheLiveMiniMaxRowIsTheFiveHourAndTheWeeklyWindow() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("5-hour window", percent: 85, isShort: true),
            candidate("coding plan (all models)", percent: 86, isShort: true),
            candidate("general (weekly window)", percent: 52, isShort: false),
            candidate("video (weekly window)", percent: 100, isShort: false, excluded: true),
            candidate("video", percent: 100, isShort: false, excluded: true),
        ])
        XCTAssertEqual(pair.short?.id, "5-hour window")
        XCTAssertEqual(pair.long?.id, "general (weekly window)")
    }

    /// The one-day window is excluded because it is MiniMax's video
    /// allowance, which is not the limit the plan is sold on.
    func testTheVideoAllowanceIsExcludedByTheSharedCapRule() {
        XCTAssertTrue(QuotaCapRule.isSupplementaryVideoQuota(
            providerKey: "minimax", modelId: "video", label: "Video"))
        XCTAssertTrue(QuotaCapRule.isSupplementaryVideoQuota(
            providerKey: "minimax", label: "video (weekly window)"))
        XCTAssertFalse(QuotaCapRule.isSupplementaryVideoQuota(
            providerKey: "minimax", label: "5-hour window"))
    }

    func testNoCandidatesGiveNoPair() {
        let pair = QuotaWindowPairing.meterPair([])
        XCTAssertNil(pair.short)
        XCTAssertNil(pair.long)
    }

    func testEveryExcludedCandidateGivesNoPair() {
        let pair = QuotaWindowPairing.meterPair([
            candidate("video", percent: 100, isShort: false, excluded: true),
        ])
        XCTAssertNil(pair.short)
        XCTAssertNil(pair.long)
    }
}
