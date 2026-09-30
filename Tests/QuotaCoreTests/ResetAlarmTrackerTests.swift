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

    func testSmallerWindowStaysQuietWhileALargerWindowIsStillAtItsCap() {
        // The 5h reset changes nothing the owner can act on: the week is spent.
        // The week's own reset announces when the provider is usable again.
        var tracker = ResetAlarmTracker()
        let fiveEnd = t0 + hour
        let weekEnd = t0 + 3 * day
        _ = tracker.process(claude(at: t0, fiveResetAt: fiveEnd, five: 0, weekResetAt: weekEnd, week: 0), now: t0)
        let later = fiveEnd + 60
        let events = tracker.process(claude(at: later, fiveResetAt: later + 5 * hour, five: 100,
                                            weekResetAt: weekEnd, week: 0), now: later)
        XCTAssertTrue(events.isEmpty)
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
