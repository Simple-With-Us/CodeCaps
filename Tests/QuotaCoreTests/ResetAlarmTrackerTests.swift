import XCTest
@testable import QuotaCore

/// Pins the reset alarm's rules (owner ruling 2026-09-30):
///
/// 1. A provider's LARGEST window fires every time it resets, even if usage
///    never came near the cap — a new week or month began.
/// 2. A SMALLER window fires on reset only if, in the period that just ended,
///    it hit the cap or came within 20% of it.
///
/// Plus the machinery that makes those rules safe to ship: the first reading
/// of a window never fires, a reset fires once and only once — across
/// restarts, repeated readings and two scopes reporting the same account —
/// and missing or late readings neither crash nor ring.
final class ResetAlarmTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    // MARK: Fixtures

    private func reading(
        _ windowId: String,
        period: TimeInterval?,
        resetAt: Date?,
        remaining: Double?,
        observedAt: Date? = nil,
        provider: String = "anthropic",
        scope: String = "local",
        label: String? = nil
    ) -> ResetAlarmObservation {
        ResetAlarmObservation(
            scope: scope,
            providerId: provider,
            providerTitle: provider == "anthropic" ? "Claude" : provider,
            windowId: windowId,
            windowLabel: label ?? windowId,
            periodSeconds: period,
            resetAt: resetAt,
            remainingPercent: remaining,
            observedAt: observedAt)
    }

    /// A Claude-shaped provider: a 5h window and a 7d window.
    private func claude(
        at now: Date,
        fiveResetAt: Date,
        five: Double?,
        weekResetAt: Date,
        week: Double?,
        scope: String = "local"
    ) -> [ResetAlarmObservation] {
        [
            reading("5h", period: 5 * hour, resetAt: fiveResetAt, remaining: five, observedAt: now, scope: scope),
            reading("7d", period: 7 * day, resetAt: weekResetAt, remaining: week, observedAt: now, scope: scope),
        ]
    }

    // MARK: First reading

    func testTheVeryFirstReadingOfAWindowNeverFires() {
        var tracker = ResetAlarmTracker()
        // A first reading that would look like a reset in every other way.
        let events = tracker.process(claude(at: t0, fiveResetAt: t0 + 5 * hour, five: 100,
                                            weekResetAt: t0 + 7 * day, week: 100), now: t0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(tracker.state.windows.count, 2)
    }

    // MARK: Rule 1 — the largest window

    func testLargestWindowFiresOnEveryResetEvenWhenUsageNeverApproachedTheCap() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 2 * hour
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 95,
                                   weekResetAt: weekEnd, week: 90), now: t0)

        let later = weekEnd + 10 * 60
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                            weekResetAt: weekEnd + 7 * day, week: 100), now: later)

        XCTAssertEqual(events.map(\.windowId), ["7d"], "only the week fires; the 5h never came near its cap")
        XCTAssertEqual(events.first?.reason, .newPeriod)
        XCTAssertEqual(events.first?.endedPeriodResetAt, weekEnd)
        XCTAssertEqual(events.first?.remainingPercent, 100)
    }

    func testAMonthlyPlanOnItsOwnIsTheLargestWindow() {
        var tracker = ResetAlarmTracker()
        let end = t0 + day
        _ = tracker.process([reading("plan", period: 30 * day, resetAt: end, remaining: 60,
                                     observedAt: t0, provider: "cursor", label: "1m")], now: t0)
        let later = end + hour
        let events = tracker.process([reading("plan", period: 30 * day, resetAt: end + 30 * day, remaining: 100,
                                              observedAt: later, provider: "cursor", label: "1m")], now: later)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .newPeriod)
        XCTAssertEqual(events.first?.windowLabel, "1m")
    }

    func testALoneWindowWithAnUnknownPeriodIsTheLargest() {
        var tracker = ResetAlarmTracker()
        let end = t0 + hour
        _ = tracker.process([reading("quota", period: nil, resetAt: end, remaining: 70,
                                     observedAt: t0, provider: "kimi")], now: t0)
        let later = end + hour
        let events = tracker.process([reading("quota", period: nil, resetAt: end + day, remaining: 100,
                                              observedAt: later, provider: "kimi")], now: later)
        XCTAssertEqual(events.map(\.reason), [.newPeriod])
    }

    // MARK: Rule 2 — smaller windows

    private func fiveHourResetEvents(minimumRemaining: Double) -> [ResetAlarmEvent] {
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + 2 * hour
        let weekEnd = t0 + 5 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 60, weekResetAt: weekEnd, week: 70), now: t0)
        let mid = t0 + hour
        _ = tracker.process(claude(at: mid, fiveResetAt: fiveEnd, five: minimumRemaining,
                                   weekResetAt: weekEnd, week: 65), now: mid)
        let later = fiveEnd + 5 * 60
        return tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                      weekResetAt: weekEnd, week: 65), now: later)
    }

    func testSmallerWindowFiresWhenItCameWithinTwentyPercentOfItsCap() {
        let events = fiveHourResetEvents(minimumRemaining: 15)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.windowId, "5h")
        XCTAssertEqual(events.first?.reason, .nearCap(minimumRemaining: 15))
    }

    func testSmallerWindowFiresWhenItHitItsCap() {
        let events = fiveHourResetEvents(minimumRemaining: 0)
        XCTAssertEqual(events.first?.reason, .nearCap(minimumRemaining: 0))
    }

    func testExactlyTwentyPercentRemainingCounts() {
        XCTAssertEqual(fiveHourResetEvents(minimumRemaining: 20).count, 1)
    }

    func testSmallerWindowStaysQuietWhenItNeverCameWithinTwentyPercent() {
        XCTAssertTrue(fiveHourResetEvents(minimumRemaining: 21).isEmpty)
        XCTAssertTrue(fiveHourResetEvents(minimumRemaining: 60).isEmpty)
    }

    func testMinimumIsTheLowestReadingOfThePeriodNotTheLast() {
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + 3 * hour
        let weekEnd = t0 + 5 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 50, weekResetAt: weekEnd, week: 70), now: t0)
        _ = tracker.process(claude(at: t0 + hour, fiveResetAt: fiveEnd, five: 12,
                                   weekResetAt: weekEnd, week: 70), now: t0 + hour)
        // An unknown reading in between neither lowers nor clears the minimum.
        _ = tracker.process(claude(at: t0 + 2 * hour, fiveResetAt: fiveEnd, five: nil,
                                   weekResetAt: weekEnd, week: 70), now: t0 + 2 * hour)
        let later = fiveEnd + 60
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                            weekResetAt: weekEnd, week: 70), now: later)
        XCTAssertEqual(events.first?.reason, .nearCap(minimumRemaining: 12))
    }

    func testSmallerWindowStillFiresWhileALargerWindowIsAtItsCap() {
        // Owner rule 2 as written: nothing but the window's own minimum decides.
        // A spent week does not silence the 5h window's reset.
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        let weekEnd = t0 + 3 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 0, weekResetAt: weekEnd, week: 0), now: t0)
        let later = fiveEnd + 60
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                            weekResetAt: weekEnd, week: 0), now: later)
        XCTAssertEqual(events.map(\.windowId), ["5h"])
        XCTAssertEqual(events.first?.reason, .nearCap(minimumRemaining: 0))
    }

    func testAModelOnlyWeeklyAtItsCapDoesNotSilenceTheFiveHourWindow() {
        // Claude reports a 7d window per model family beside the overall one.
        // The Sonnet cap can be spent while Claude is perfectly usable.
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        let weekEnd = t0 + 4 * day
        func batch(at now: Date, five: Double, fiveReset: Date) -> [ResetAlarmObservation] {
            [
                reading("5h", period: 5 * hour, resetAt: fiveReset, remaining: five, observedAt: now),
                reading("7d", period: 7 * day, resetAt: weekEnd, remaining: 60, observedAt: now),
                reading("7d_sonnet", period: 7 * day, resetAt: weekEnd, remaining: 0, observedAt: now),
            ]
        }
        _ = tracker.process(batch(at: t0, five: 10, fiveReset: fiveEnd), now: t0)
        let later = fiveEnd + 60
        let events = tracker.process(batch(at: later, five: 100, fiveReset: later + 5 * hour), now: later)
        XCTAssertEqual(events.map(\.windowId), ["5h"])
    }

    func testAnotherModelsWeeklyAtItsCapDoesNotSilenceAModelsIntervalWindow() {
        // MiniMax reports an interval and a weekly window per model.
        var tracker = ResetAlarmTracker()
        let intervalEnd = t0 + hour
        let weekEnd = t0 + 4 * day
        func batch(at now: Date, intervalB: Double, intervalReset: Date) -> [ResetAlarmObservation] {
            [
                reading("A:weekly", period: 7 * day, resetAt: weekEnd, remaining: 0, observedAt: now, provider: "minimax"),
                reading("A:interval", period: 5 * hour, resetAt: intervalReset, remaining: 70, observedAt: now, provider: "minimax"),
                reading("B:weekly", period: 7 * day, resetAt: weekEnd, remaining: 50, observedAt: now, provider: "minimax"),
                reading("B:interval", period: 5 * hour, resetAt: intervalReset, remaining: intervalB, observedAt: now, provider: "minimax"),
            ]
        }
        _ = tracker.process(batch(at: t0, intervalB: 5, intervalReset: intervalEnd), now: t0)
        let later = intervalEnd + 60
        let events = tracker.process(batch(at: later, intervalB: 100, intervalReset: later + 5 * hour), now: later)
        XCTAssertTrue(events.contains { $0.windowId == "B:interval" }, "model B's interval came within 20% and reset")
    }

    func testBothWindowsResettingTogetherFireLargestFirst() {
        var tracker = ResetAlarmTracker()
        let end = t0 + hour
        _ = tracker.process(claude(at: t0, fiveResetAt: end, five: 4, weekResetAt: end, week: 30), now: t0)
        let later = end + 60
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                            weekResetAt: end + 7 * day, week: 100), now: later)
        XCTAssertEqual(events.map(\.windowId), ["7d", "5h"])
    }

    func testARefreshThatMissesTheWeeklyWindowDoesNotPromoteTheFiveHourWindow() {
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 80,
                                   weekResetAt: t0 + 4 * day, week: 70), now: t0)
        let later = fiveEnd + 60
        // Only the 5h window comes back this time.
        let events = tracker.process([reading("5h", period: 5 * hour, resetAt: later + 5 * hour,
                                              remaining: 100, observedAt: later)], now: later)
        XCTAssertTrue(events.isEmpty, "the 5h window is still the smaller window and never came near its cap")
    }

    // MARK: Once and only once

    func testTheSameResetNeverFiresTwice() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + hour
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 90,
                                   weekResetAt: weekEnd, week: 50), now: t0)
        let later = weekEnd + 60
        let next = claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                          weekResetAt: weekEnd + 7 * day, week: 100)
        XCTAssertEqual(tracker.process(next, now: later).count, 1)

        // The same readings again, and again with a few seconds of jitter.
        XCTAssertTrue(tracker.process(next, now: later + 300).isEmpty)
        let jittered = claude(at: later + 600, fiveResetAt: later + 5 * hour + 20, five: 99,
                              weekResetAt: weekEnd + 7 * day + 20, week: 99)
        XCTAssertTrue(tracker.process(jittered, now: later + 600).isEmpty)
    }

    func testRestartKeepsAPendingResetAndDoesNotRefireIt() {
        // Before the restart: the 5h window reaches 8% in its period.
        var before = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        let weekEnd = t0 + 4 * day
        _ = before.process(claude(at: t0, fiveResetAt: fiveEnd, five: 8, weekResetAt: weekEnd, week: 60), now: t0)
        let saved = before.state.encoded()
        XCTAssertNotNil(saved)

        // The app is down while the window resets.  After the relaunch the
        // first reading reveals the reset, and it still fires, once.
        var afterRelaunch = ResetAlarmTracker(state: ResetAlarmTrackerState.decoded(from: saved))
        let later = fiveEnd + 2 * hour
        let readings = claude(at: later, fiveResetAt: later + 5 * hour, five: 100, weekResetAt: weekEnd, week: 60)
        let fired = afterRelaunch.process(readings, now: later)
        XCTAssertEqual(fired.map(\.windowId), ["5h"])
        XCTAssertEqual(fired.first?.reason, .nearCap(minimumRemaining: 8))

        // A second relaunch (a Sparkle update, say) sees the same readings.
        var secondRelaunch = ResetAlarmTracker(state: ResetAlarmTrackerState.decoded(from: afterRelaunch.state.encoded()))
        XCTAssertTrue(secondRelaunch.process(readings, now: later + 60).isEmpty)
    }

    func testCorruptSavedStateStartsEmptyAndDoesNotFire() {
        var tracker = ResetAlarmTracker(state: ResetAlarmTrackerState.decoded(from: Data("not json".utf8)))
        XCTAssertTrue(tracker.state.windows.isEmpty)
        XCTAssertTrue(tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 0,
                                             weekResetAt: t0 + day, week: 0), now: t0).isEmpty)
    }

    func testTheSameResetReportedByThisMacAndTheFleetRingsOnce() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + hour
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 90, weekResetAt: weekEnd, week: 40)
            + claude(at: t0, fiveResetAt: t0 + hour, five: 90, weekResetAt: weekEnd + 30, week: 40, scope: "fleet:mini"),
            now: t0)
        let later = weekEnd + 60
        let events = tracker.process(
            claude(at: later, fiveResetAt: later + 5 * hour, five: 100, weekResetAt: weekEnd + 7 * day, week: 100)
            + claude(at: later, fiveResetAt: later + 5 * hour, five: 100, weekResetAt: weekEnd + 7 * day, week: 100,
                     scope: "fleet:mini"),
            now: later)
        XCTAssertEqual(events.count, 1, "one account, one reset, one alarm")
    }

    func testTwoAccountsOnTwoMachinesFireSeparately() {
        var tracker = ResetAlarmTracker()
        let localWeekEnd = t0 + hour
        let fleetWeekEnd = t0 + 2 * hour
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 90, weekResetAt: localWeekEnd, week: 40)
            + claude(at: t0, fiveResetAt: t0 + hour, five: 90, weekResetAt: fleetWeekEnd, week: 40, scope: "fleet:mini"),
            now: t0)
        let later = fleetWeekEnd + 60
        let events = tracker.process(
            claude(at: later, fiveResetAt: later + 5 * hour, five: 100, weekResetAt: localWeekEnd + 7 * day, week: 100)
            + claude(at: later, fiveResetAt: later + 5 * hour, five: 100, weekResetAt: fleetWeekEnd + 7 * day, week: 100,
                     scope: "fleet:mini"),
            now: later)
        XCTAssertEqual(Set(events.map(\.scope)), ["local", "fleet:mini"])
    }

    // MARK: Detecting a reset

    func testResetIsDetectedWhenTheOldResetPassedAndRemainingRoseWithoutANewResetTime() {
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        let weekEnd = t0 + 4 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 5, weekResetAt: weekEnd, week: 60), now: t0)

        // The reader has not published the next reset yet, but the percentage
        // is back up and the old reset time is behind us.
        let later = fiveEnd + 10 * 60
        let events = tracker.process([
            reading("5h", period: 5 * hour, resetAt: nil, remaining: 100, observedAt: later),
            reading("7d", period: 7 * day, resetAt: weekEnd, remaining: 60, observedAt: later),
        ], now: later)
        XCTAssertEqual(events.map(\.windowId), ["5h"])

        // When the next reset time does arrive, it is adopted, not re-announced.
        let next = later + 5 * 60
        XCTAssertTrue(tracker.process(claude(at: next, fiveResetAt: next + 5 * hour, five: 100,
                                             weekResetAt: weekEnd, week: 60), now: next).isEmpty)
    }

    func testMidWindowResetFiresWhenQuotaSurgesOrJumpsToFullBeforePeriodEnd() {
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + 4 * hour
        let weekEnd = t0 + 4 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 75, weekResetAt: weekEnd, week: 60), now: t0)

        // 30 minutes in (reset still 3.5h away): surged from under 80% to >= 95%
        let mid1 = t0 + 30 * 60
        let events1 = tracker.process(claude(at: mid1, fiveResetAt: fiveEnd, five: 96, weekResetAt: weekEnd, week: 60), now: mid1)
        XCTAssertEqual(events1.map(\.windowId), ["5h"])

        // Drops to 15%, then jumps to 100% mid-window
        let mid2 = t0 + 60 * 60
        _ = tracker.process(claude(at: mid2, fiveResetAt: fiveEnd, five: 15, weekResetAt: weekEnd, week: 60), now: mid2)

        let mid3 = t0 + 70 * 60
        let events2 = tracker.process(claude(at: mid3, fiveResetAt: fiveEnd, five: 100, weekResetAt: weekEnd, week: 60), now: mid3)
        XCTAssertEqual(events2.map(\.windowId), ["5h"])
    }

    func testAStaleResetTimeRepeatedAfterADetectedResetIsNotASecondReset() {
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        let weekEnd = t0 + 4 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 5, weekResetAt: weekEnd, week: 60), now: t0)
        let later = fiveEnd + 10 * 60
        // The reader keeps echoing the stale reset time with a fresh percentage.
        let stale = claude(at: later, fiveResetAt: fiveEnd, five: 100, weekResetAt: weekEnd, week: 60)
        XCTAssertEqual(tracker.process(stale, now: later).count, 1)
        XCTAssertTrue(tracker.process(claude(at: later + 60, fiveResetAt: fiveEnd, five: 97,
                                             weekResetAt: weekEnd, week: 60), now: later + 60).isEmpty)
        let next = later + 120
        XCTAssertTrue(tracker.process(claude(at: next, fiveResetAt: next + 5 * hour, five: 96,
                                             weekResetAt: weekEnd, week: 60), now: next).isEmpty)
    }

    func testResetTimeJitterNeverAddsUpToAReset() {
        var tracker = ResetAlarmTracker()
        var fiveEnd = t0 + 4 * hour
        let weekEnd = t0 + 3 * day
        var now = t0
        for _ in 0..<40 {
            fiveEnd += 30  // "now plus the seconds left", computed a little late each time
            let events = tracker.process(claude(at: now, fiveResetAt: fiveEnd, five: 3,
                                                weekResetAt: weekEnd, week: 50), now: now)
            XCTAssertTrue(events.isEmpty)
            now += 60
        }
    }

    func testARollingResetThatCreepsForwardWhileTheMacSleepsIsNotAReset() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 3 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + 4 * hour, five: 10,
                                   weekResetAt: weekEnd, week: 50), now: t0)
        // An hour asleep; a rolling window's reset moved an hour later.
        let woke = t0 + hour
        XCTAssertTrue(tracker.process(claude(at: woke, fiveResetAt: t0 + 5 * hour, five: 10,
                                             weekResetAt: weekEnd + hour, week: 50), now: woke).isEmpty)
    }

    // MARK: - Vendor restores that do not land at 100%

    /// On 2026-10-04 both Cursor and Grok Bot had their quota restored
    /// mid-cycle and neither rang.  Reproduced here from the numbers in the
    /// live tracker state: Cursor's included plan went 15.08% to 89.02% and
    /// Grok Bot's weekly went 52.45% to 91.96%, in both cases with the period
    /// end left exactly where it was.
    ///
    /// The old rule only fired when a restore landed at 95% or above, so a
    /// vendor that gives back a partial allowance looked like ordinary drift.
    /// A fixed-period window cannot regain quota inside its own period, so a
    /// large rise is the signal and the level it lands at is not.
    func testAVendorRestoreBelow95PercentIsDetected() {
        var tracker = ResetAlarmTracker()
        // Cursor: a 30-day billing cycle, thirteen days left when it was restored.
        let cursorEnd = t0 + 13 * day
        _ = tracker.process(
            [reading("plan", period: 30 * day, resetAt: cursorEnd, remaining: 15.08, observedAt: t0, provider: "cursor")],
            now: t0)

        let cursorLater = t0 + 4 * hour
        let cursorEvents = tracker.process(
            [reading("plan", period: 30 * day, resetAt: cursorEnd, remaining: 89.02, observedAt: cursorLater, provider: "cursor")],
            now: cursorLater)
        XCTAssertEqual(cursorEvents.map(\.windowId), ["plan"])
        XCTAssertEqual(cursorEvents.first?.isVendorReset, true, "A mid-cycle restore is a vendor reset.")
    }

    func testAPartialRestoreOfEverySizeIsDetected() {
        // 56.45% to 91.96% is a 35-point rise that never reaches 95%.
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: weekEnd, remaining: 56.45, observedAt: t0, provider: "grok-bot")],
            now: t0)

        let later = t0 + 3 * hour
        let events = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: weekEnd, remaining: 91.96, observedAt: later, provider: "grok-bot")],
            now: later)
        XCTAssertEqual(events.map(\.windowId), ["weekly"])
        XCTAssertEqual(events.first?.isVendorReset, true)
    }

    /// A rise is only new evidence when the period end holds still.  When the
    /// end moves too, the earlier rule already calls it an early reset — a
    /// provider resetting a limit early moves its reset time and the quota
    /// climbs — so this rule adds nothing there and must not change it.
    func testARiseWhosePeriodEndAlsoMovesIsStillAnEarlyReset() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 56.45, observedAt: t0, provider: "grok-bot")],
            now: t0)

        let later = t0 + 3 * hour
        let events = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end + 3 * hour, remaining: 91.96, observedAt: later, provider: "grok-bot")],
            now: later)
        XCTAssertEqual(events.map(\.windowId), ["weekly"], "A moved period end is an early reset.")
    }

    /// A large rise inside the drift tolerance is still the end holding still:
    /// a provider recomputing "now plus the seconds left" jitters by seconds.
    func testAHandedBackQuotaIsDetectedDespiteResetTimeJitter() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 15.0, observedAt: t0, provider: "grok-bot")],
            now: t0)
        let later = t0 + hour
        let events = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end + 60, remaining: 89.0, observedAt: later, provider: "grok-bot")],
            now: later)
        XCTAssertEqual(events.map(\.windowId), ["weekly"])
        XCTAssertEqual(events.first?.isVendorReset, true)
    }

    /// Small drift is still drift, not a restore.
    func testASmallMidWindowRiseIsNotAReset() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 88.0, observedAt: t0, provider: "grok-bot")],
            now: t0)
        let later = t0 + 20 * 60
        XCTAssertTrue(tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 91.0, observedAt: later, provider: "grok-bot")],
            now: later).isEmpty)
    }

    /// Found in review on PR #153: a rolling window at the app's real 300s
    /// refresh cadence slid its period end five minutes per poll, which sat
    /// inside the old fixed 15-minute tolerance.  So a rolling window whose
    /// usage aged out by 30 points or more satisfied both halves of the rule
    /// and was announced as a vendor reset.
    ///
    /// The harm went further than a wrong notification: a detected reset
    /// overwrites the low-water mark, which is the only record of how close the
    /// window got, so the genuine near-cap alarm at the next period end would
    /// have been silenced.
    func testARollingWindowThatSlidesItsEndEveryRefreshIsNotAVendorRestore() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        // Two quiet polls, five minutes apart, each sliding the end five minutes
        // forward — a reader reporting "resets in N seconds" recomputed from the
        // current time.  Then one poll sees a 35-point rise as a burst of usage
        // ages out.  35 clears the 30-point bar, so only the "end held still"
        // half of the rule stands between this and a bogus vendor reset.
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 15.0, observedAt: t0, provider: "grok-bot")],
            now: t0)
        let poll1 = t0 + 5 * 60
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end + 5 * 60, remaining: 15.0, observedAt: poll1, provider: "grok-bot")],
            now: poll1)
        let poll2 = t0 + 10 * 60
        let events = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end + 10 * 60, remaining: 50.0, observedAt: poll2, provider: "grok-bot")],
            now: poll2)
        XCTAssertTrue(events.isEmpty, "A period end that slides with the clock is rolling, not a restore.")

        // And the low-water mark survives, so the near-cap alarm can still fire.
        let key = ResetAlarmTracker.windowKey(scope: "local", providerId: "grok-bot", windowId: "weekly")
        XCTAssertEqual(tracker.state.windows[key]?.minimumRemaining, 15.0)
    }

    /// A real vendor restore is still detected at every refresh cadence.
    /// Found in review on PR #153: bounding the tolerance by the poll gap meant
    /// a held end was judged more strictly the more often the owner refreshed,
    /// so the same restore could fire at a slow cadence and be dropped at a
    /// fast one.  "Held still" is now a flat bound, which makes an end that did
    /// not move classify identically whether the gap was 30 seconds or an hour.
    ///
    /// The slide test that backs it up is deliberately a ratio — that is the
    /// only way to recognise a sliding end at all, and it necessarily compares
    /// against elapsed time.  What is guaranteed here is the guarantee that
    /// matters: a genuine restore is never dropped because of refresh timing.
    func testARealRestoreIsDetectedAtEveryRefreshCadence() {
        for gap in [30.0, 300.0, 3_600.0] {
            var tracker = ResetAlarmTracker()
            let end = t0 + 5 * day
            _ = tracker.process(
                [reading("weekly", period: 7 * day, resetAt: end, remaining: 15.0, observedAt: t0, provider: "grok-bot")],
                now: t0)
            let later = t0 + gap
            let events = tracker.process(
                [reading("weekly", period: 7 * day, resetAt: end, remaining: 89.0, observedAt: later, provider: "grok-bot")],
                now: later)
            XCTAssertEqual(events.map(\.windowId), ["weekly"], "Gap of \(Int(gap))s must still detect a restore.")
            XCTAssertEqual(events.first?.isVendorReset, true, "Gap of \(Int(gap))s.")
        }
    }

    /// A rolling window at the 30-second clock-timer cadence, where the slide
    /// and the absolute floor are the same size.  Also found in review: a floor
    /// pinned the bound above the slide at short gaps, and the manual Refresh
    /// buttons plus the 30s `clockTimer` make those gaps ordinary.
    func testARollingWindowAtTheThirtySecondCadenceIsNotAVendorRestore() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 15.0, observedAt: t0, provider: "grok-bot")],
            now: t0)
        let later = t0 + 30
        let events = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end + 30, remaining: 50.0, observedAt: later, provider: "grok-bot")],
            now: later)
        XCTAssertTrue(events.isEmpty, "A 30-second slide is still a slide.")

        let key = ResetAlarmTracker.windowKey(scope: "local", providerId: "grok-bot", windowId: "weekly")
        XCTAssertEqual(tracker.state.windows[key]?.minimumRemaining, 15.0)
    }

    /// `observedAt` is optional at the only production construction site, so an
    /// unstamped provider arrives with no elapsed time to judge by.  With no
    /// time gap there is no way to show the end slid, so a held end plus a
    /// large rise is still a restore rather than a permanent silent miss.
    func testAnUnstampedProviderStillDetectsARealRestore() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 15.0, observedAt: nil, provider: "grok-bot")],
            now: t0)
        let later = t0 + 300
        let events = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 89.0, observedAt: nil, provider: "grok-bot")],
            now: later)
        XCTAssertEqual(events.map(\.windowId), ["weekly"])
        XCTAssertEqual(events.first?.isVendorReset, true)
    }

    /// One restore rings once, not once per refresh.
    func testAVendorRestoreRingsOnlyOnce() {
        var tracker = ResetAlarmTracker()
        let end = t0 + 5 * day
        _ = tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 15.0, observedAt: t0, provider: "grok-bot")],
            now: t0)
        let first = t0 + hour
        XCTAssertEqual(tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 89.0, observedAt: first, provider: "grok-bot")],
            now: first).count, 1)
        let second = t0 + 2 * hour
        XCTAssertTrue(tracker.process(
            [reading("weekly", period: 7 * day, resetAt: end, remaining: 87.0, observedAt: second, provider: "grok-bot")],
            now: second).isEmpty)
    }

    func testAnEarlyResetByTheProviderStillCounts() {
        // A provider that resets a limit early moves the reset a whole period.
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 3 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + 4 * hour, five: 90,
                                   weekResetAt: weekEnd, week: 30), now: t0)
        let later = t0 + hour
        let events = tracker.process(claude(at: later, fiveResetAt: t0 + 4 * hour, five: 90,
                                            weekResetAt: later + 7 * day, week: 100), now: later)
        XCTAssertEqual(events.map(\.windowId), ["7d"])
    }

    func testAnEarlyResetWithAShortJumpStillCountsWhenThePercentageClimbsBack() {
        // The week is at 30% with 5 days left; the provider resets it and the
        // new reset time is 7 days away, a move of 2 days, well under half a
        // 7-day period.  The percentage going back to 100 settles it.
        var tracker = ResetAlarmTracker()
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + 4 * hour, five: 90,
                                   weekResetAt: t0 + 5 * day, week: 30), now: t0)
        let later = t0 + hour
        let events = tracker.process(claude(at: later, fiveResetAt: t0 + 4 * hour, five: 90,
                                            weekResetAt: later + 7 * day, week: 100), now: later)
        XCTAssertEqual(events.map(\.windowId), ["7d"])
        XCTAssertEqual(tracker.state.windows["local|anthropic|7d"]?.minimumRemaining, 100,
                       "the new period starts from the new reading, not the old minimum")
    }

    func testAShortJumpWithoutAClimbIsStillJustADrift() {
        var tracker = ResetAlarmTracker()
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + 4 * hour, five: 90,
                                   weekResetAt: t0 + 5 * day, week: 30), now: t0)
        let later = t0 + hour
        // The reset time moved two days, but the percentage did not recover.
        let events = tracker.process(claude(at: later, fiveResetAt: t0 + 4 * hour, five: 90,
                                            weekResetAt: t0 + 7 * day, week: 32), now: later)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: Whose window it is

    func testAWindowThatChangesHandsStartsOverWithoutFiring() {
        // Grok Bot reuses one window id for whichever account is active.  The
        // other account's reset is six days out; it is not this one's reset.
        var tracker = ResetAlarmTracker()
        func gbu(account: String, remaining: Double, resetAt: Date, at now: Date) -> [ResetAlarmObservation] {
            [ResetAlarmObservation(scope: "local", providerId: "grok-bot", providerTitle: "Grok Bot",
                                   windowId: "gbu-weekly", windowLabel: "7d", periodSeconds: 7 * day,
                                   resetAt: resetAt, remainingPercent: remaining, observedAt: now,
                                   identity: account)]
        }
        _ = tracker.process(gbu(account: "a", remaining: 0, resetAt: t0 + 2 * day, at: t0), now: t0)
        let later = t0 + hour
        XCTAssertTrue(tracker.process(gbu(account: "b", remaining: 80, resetAt: t0 + 6 * day, at: later),
                                      now: later).isEmpty)
        XCTAssertEqual(tracker.state.windows["local|grok-bot|gbu-weekly"]?.identity, "b")
        XCTAssertEqual(tracker.state.windows["local|grok-bot|gbu-weekly"]?.minimumRemaining, 80,
                       "account a's 0% must not leak into account b's period")
        // Account b then resets for real, and the largest window announces it.
        let reset = t0 + 6 * day + 60
        XCTAssertEqual(tracker.process(gbu(account: "b", remaining: 100, resetAt: t0 + 13 * day, at: reset),
                                       now: reset).map(\.windowId), ["gbu-weekly"])
    }

    func testAWindowWithoutAnIdentityAdoptsTheFirstOneWithoutRestarting() {
        var tracker = ResetAlarmTracker()
        var first = reading("7d", period: 7 * day, resetAt: t0 + 2 * day, remaining: 40, observedAt: t0)
        _ = tracker.process([first], now: t0)
        first.identity = "a"
        first.observedAt = t0 + hour
        _ = tracker.process([first], now: t0 + hour)
        XCTAssertEqual(tracker.state.windows["local|anthropic|7d"]?.identity, "a")
        XCTAssertEqual(tracker.state.windows["local|anthropic|7d"]?.minimumRemaining, 40)
    }

    func testStateSavedBeforeIdentitiesExistedStillDecodes() throws {
        let old = """
        {"version":1,"recentFires":[],"windows":{"local|anthropic|7d":{"periodResetAt":1790100000,"minimumRemaining":40,"lastRemaining":40,"lastSeenAt":1790000000,"periodSeconds":604800}}}
        """
        let decoded = ResetAlarmTrackerState.decoded(from: Data(old.utf8))
        XCTAssertEqual(decoded.windows["local|anthropic|7d"]?.minimumRemaining, 40)
        XCTAssertNil(decoded.windows["local|anthropic|7d"]?.identity)
    }

    // MARK: Missing and late readings

    func testReadingsWithNoPercentageOrNoResetAreTolerated() {
        var tracker = ResetAlarmTracker()
        let unknown = [
            reading("5h", period: 5 * hour, resetAt: nil, remaining: nil, observedAt: t0),
            reading("7d", period: 7 * day, resetAt: nil, remaining: nil, observedAt: t0),
        ]
        XCTAssertTrue(tracker.process(unknown, now: t0).isEmpty)
        XCTAssertTrue(tracker.process(unknown, now: t0 + hour).isEmpty)

        // A reset time finally appears: adopted, not a reset.
        let weekEnd = t0 + 2 * day
        XCTAssertTrue(tracker.process(claude(at: t0 + 2 * hour, fiveResetAt: t0 + 4 * hour, five: nil,
                                             weekResetAt: weekEnd, week: nil), now: t0 + 2 * hour).isEmpty)

        // The week resets with no percentage ever seen: the largest window
        // still announces it; the 5h window, never seen near its cap, does not.
        let later = weekEnd + hour
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: nil,
                                            weekResetAt: weekEnd + 7 * day, week: nil), now: later)
        XCTAssertEqual(events.map(\.windowId), ["7d"])
    }

    func testAReadingOlderThanOneAlreadyProcessedIsIgnored() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + hour
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 50, weekResetAt: weekEnd, week: 50), now: t0)
        let later = weekEnd + 60
        XCTAssertEqual(tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                              weekResetAt: weekEnd + 7 * day, week: 100), now: later).count, 1)
        // A late fleet report from before the reset must not rewind the window,
        // or the next fresh reading would announce the same reset again.
        XCTAssertTrue(tracker.process(claude(at: t0 + 30 * 60, fiveResetAt: t0 + hour, five: 10,
                                             weekResetAt: weekEnd, week: 10), now: later + 60).isEmpty)
        XCTAssertTrue(tracker.process(claude(at: later + 120, fiveResetAt: later + 5 * hour, five: 99,
                                             weekResetAt: weekEnd + 7 * day, week: 99), now: later + 120).isEmpty)
    }

    func testOneFutureStampedReadingDoesNotFreezeTheWindow() {
        // A fleet producer with a wrong clock stamps a reading a day ahead.
        // Every honest reading after it must still count.
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + 2 * hour
        let weekEnd = t0 + 3 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 60, weekResetAt: weekEnd, week: 50,
                                   scope: "fleet:mini"), now: t0)
        let skewed = t0 + 10 * 60
        _ = tracker.process(claude(at: t0 + day, fiveResetAt: fiveEnd, five: 55, weekResetAt: weekEnd, week: 50,
                                   scope: "fleet:mini"), now: skewed)
        // The honest readings take the 5h window to 5%, then it resets.
        let low = t0 + hour
        _ = tracker.process(claude(at: low, fiveResetAt: fiveEnd, five: 5, weekResetAt: weekEnd, week: 50,
                                   scope: "fleet:mini"), now: low)
        XCTAssertEqual(tracker.state.windows["fleet:mini|anthropic|5h"]?.minimumRemaining, 5)
        let later = fiveEnd + 60
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                            weekResetAt: weekEnd, week: 50, scope: "fleet:mini"), now: later)
        XCTAssertEqual(events.map(\.windowId), ["5h"])
        XCTAssertEqual(events.first?.reason, .nearCap(minimumRemaining: 5))
    }

    func testForgottenWindowsArePrunedAfterTheRetentionPeriod() {
        var tracker = ResetAlarmTracker()
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 50, weekResetAt: t0 + day, week: 50), now: t0)
        XCTAssertEqual(tracker.state.windows.count, 2)
        _ = tracker.process([], now: t0 + ResetAlarmPolicy.retention + day)
        XCTAssertTrue(tracker.state.windows.isEmpty)
    }

    func testStateRoundTripsThroughItsEncoding() {
        var tracker = ResetAlarmTracker()
        _ = tracker.process(claude(at: t0, fiveResetAt: t0 + hour, five: 12, weekResetAt: t0 + day, week: 40), now: t0)
        let decoded = ResetAlarmTrackerState.decoded(from: tracker.state.encoded())
        XCTAssertEqual(decoded, tracker.state)
    }
}
