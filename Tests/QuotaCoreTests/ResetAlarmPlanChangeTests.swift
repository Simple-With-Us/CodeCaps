import XCTest
@testable import QuotaCore

/// How a mid-cycle restore is named, and what happens when the quota does not
/// come all the way back.
///
/// Owner ruling 2026-10-20: "we shouldn't consider it vendor reset unless it
/// jumps up a large amount and we see it actually at 97-100% or something
/// (just random guess, maybe 95-100 or maybe 99-100 is better, but the point
/// is that we may not notice the first initial usage after a reset so we can
/// consider that a vendor reset.  So the Muse Code shouldn't have said vendor
/// reset, and in fact it should have said 'likely plan change'".
///
/// The two false positives that ruling was written against are the two cases
/// pinned here: Muse Code, where an upgrade took the allowance from 0% to 75%,
/// and Antigravity, where a five-hour window raised a vendor reset while the
/// weekly underneath it was still spent.
final class ResetAlarmPlanChangeTests: XCTestCase {
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
        provider: String = "musecode"
    ) -> ResetAlarmObservation {
        ResetAlarmObservation(
            scope: "local",
            providerId: provider,
            providerTitle: "Muse Code",
            windowId: windowId,
            windowLabel: windowId,
            periodSeconds: period,
            resetAt: resetAt,
            remainingPercent: remaining,
            observedAt: observedAt)
    }

    /// One provider with one weekly window, the shape Muse Code reports.
    private func weekly(
        at now: Date,
        resetAt: Date,
        remaining: Double?,
        provider: String = "musecode"
    ) -> [ResetAlarmObservation] {
        [reading("7d", period: 7 * day, resetAt: resetAt, remaining: remaining,
                 observedAt: now, provider: provider)]
    }

    // MARK: The level decides the name

    /// The owner's own false positive: the plan was upgraded, the allowance
    /// went from nothing to 75%, and the app called it a vendor reset.
    func testAPlanUpgradeIsReportedAsAPlanChangeAndNotAVendorReset() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 7 * self.day
        _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 0), now: t0)

        // The upgrade: the same window, the same end, and 75% back.
        let later = t0 + 2 * self.hour
        let events = tracker.process(weekly(at: later, resetAt: weekEnd, remaining: 75), now: later)

        XCTAssertEqual(events.count, 1, "the change still has to be reported")
        XCTAssertFalse(events[0].isVendorReset, "a rise to 75% is not a vendor reset")
        XCTAssertTrue(events[0].isPlanChange, "a rise that lands below the full level is a likely plan change")
        XCTAssertEqual(events[0].reason, .planChange)
        XCTAssertEqual(events[0].remainingPercent, 75)
    }

    /// The owner's other case, and the one that must not regress: Codex reset
    /// its quota and the alert for it was right.
    func testAVendorRestoreToFullIsStillAVendorReset() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 7 * self.day
        _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 0), now: t0)

        let later = t0 + 2 * self.hour
        let events = tracker.process(weekly(at: later, resetAt: weekEnd, remaining: 100), now: later)

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isVendorReset, "a restore to full is a vendor reset")
        XCTAssertFalse(events[0].isPlanChange)
    }

    func testMidWindowRestoreFromLowNinetiesToFullStillCountsAsAVendorReset() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 7 * day
        _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 92), now: t0)

        let later = t0 + 2 * hour
        let events = tracker.process(weekly(at: later, resetAt: weekEnd, remaining: 100), now: later)

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isVendorReset, "a full refill remains a vendor reset even after some intervening use")
    }

    func testPreExpirySmallDeadlineNudgeAndTenPointRiseIsNotAReset() {
        var tracker = ResetAlarmTracker()
        let oldEnd = t0 + 5 * day
        _ = tracker.process(weekly(at: t0, resetAt: oldEnd, remaining: 72), now: t0)

        let later = t0 + hour
        let nudgedEnd = oldEnd + 16 * 60
        let events = tracker.process(weekly(at: later, resetAt: nudgedEnd, remaining: 84), now: later)

        XCTAssertTrue(events.isEmpty, "a 16-minute nudge is not a weekly reset even when quota rises by ten points")
        XCTAssertEqual(tracker.state.windows[ResetAlarmTracker.windowKey(scope: "local", providerId: "musecode", windowId: "7d")]?.periodResetAt,
                       nudgedEnd)
    }

    /// The line itself.  The floor is 95 rather than 99 because the first
    /// reading after a reset can already carry a little usage.
    func testTheLevelTheQuotaLandsAtDecidesWhichNameItGets() {
        XCTAssertEqual(ResetAlarmPolicy.vendorRestoreLevel, 95)

        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 7 * self.day
        _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 0), now: t0)
        let later = t0 + 2 * self.hour
        let events = tracker.process(weekly(at: later, resetAt: weekEnd, remaining: 95), now: later)

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isVendorReset, "95% is at the floor and is a vendor reset")
        XCTAssertFalse(events[0].isPlanChange)
    }

    func testARiseThatStopsJustBelowTheFloorIsAPlanChange() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 7 * self.day
        _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 0), now: t0)
        let later = t0 + 2 * self.hour
        let events = tracker.process(weekly(at: later, resetAt: weekEnd, remaining: 94.9), now: later)

        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].isPlanChange)
        XCTAssertFalse(events[0].isVendorReset)
    }

    // MARK: A window whose number must not be believed

    /// The owner's Antigravity case: "Antigravity is saying vendor reset 5h
    /// quota early while the 7d is still at cap and unchanged, so that alarm
    /// yesterday shouldn't have gone off."
    ///
    /// The five-hour window under a spent weekly cap reports no percentage on
    /// purpose, so the quota cannot be seen to come back and the window has
    /// nothing to say about a restore.
    func testAWindowWhosePercentageMustNotBeBelievedCannotRaiseAVendorReset() {
        var tracker = ResetAlarmTracker()
        let provider = "google-antigravity:gemini"
        let fiveEnd = t0 + 5 * self.hour
        let weekEnd = t0 + 7 * self.day

        _ = tracker.process([
            reading("5h", period: 5 * self.hour, resetAt: fiveEnd, remaining: nil,
                    observedAt: t0, provider: provider),
            reading("weekly", period: 7 * self.day, resetAt: weekEnd, remaining: 0,
                    observedAt: t0, provider: provider),
        ], now: t0)

        // The five-hour end jumps forward while the weekly stays exactly where
        // it was, at zero.
        let later = t0 + self.hour
        let events = tracker.process([
            reading("5h", period: 5 * self.hour, resetAt: t0 + 10 * self.hour, remaining: nil,
                    observedAt: later, provider: provider),
            reading("weekly", period: 7 * self.day, resetAt: weekEnd, remaining: 0,
                    observedAt: later, provider: provider),
        ], now: later)

        XCTAssertTrue(events.isEmpty,
                      "a window whose number must not be believed raises no alarm at all")
        XCTAssertTrue(events.allSatisfy { !$0.isVendorReset },
                      "a window with no readable percentage cannot claim a vendor reset")
        XCTAssertTrue(events.allSatisfy { !$0.isPlanChange })
    }

    /// The same window, but it had a readable percentage before it was masked
    /// and that percentage was near its cap.  The ordinary rollover path would
    /// otherwise claim it and report a reset that nobody can confirm, while the
    /// weekly underneath it is still spent.
    func testAMaskedWindowWithAReadablePastRaisesNoAlarmEvenNearItsCap() {
        var tracker = ResetAlarmTracker()
        let provider = "google-antigravity:gemini"
        let fiveEnd = t0 + 5 * self.hour
        let weekEnd = t0 + 7 * self.day

        // The five-hour window is readable at first, and nearly spent.
        _ = tracker.process([
            reading("5h", period: 5 * self.hour, resetAt: fiveEnd, remaining: 2,
                    observedAt: t0, provider: provider),
            reading("weekly", period: 7 * self.day, resetAt: weekEnd, remaining: 0,
                    observedAt: t0, provider: provider),
        ], now: t0)

        // The weekly is spent, so the five-hour window now reports nothing.
        // Its own end still moves.
        let later = t0 + self.hour
        let events = tracker.process([
            reading("5h", period: 5 * self.hour, resetAt: t0 + 10 * self.hour, remaining: nil,
                    observedAt: later, provider: provider),
            reading("weekly", period: 7 * self.day, resetAt: weekEnd, remaining: 0,
                    observedAt: later, provider: provider),
        ], now: later)

        XCTAssertTrue(events.isEmpty,
                      "a masked window raises no alarm even when its last readable reading was near the cap")
    }

    /// A mid-cycle event needs evidence that the quota rose.  A window whose
    /// reported end jumped early can also be a window whose quota went down,
    /// and calling that a plan change would tell the owner the quota rose when
    /// the opposite happened.
    func testAMidCycleEventThatFellIsNeitherARefillNorAPlanChange() {
        var tracker = ResetAlarmTracker()
        let weekEnd = t0 + 7 * self.day
        _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 74), now: t0)

        // The saved MiniMax alerts held at 74%, then fell to 73% while the reported end moved forward.
        let later = t0 + 2 * self.hour
        let events = tracker.process(weekly(at: later, resetAt: t0 + 11 * self.day, remaining: 73), now: later)

        XCTAssertTrue(events.isEmpty, "a future-end correction with falling quota is not a reset")

        // Adopt the corrected end, then still report its actual scheduled rollover.
        let scheduled = t0 + 11 * self.day + 60
        let rollover = tracker.process(weekly(at: scheduled, resetAt: scheduled + 7 * self.day,
                                              remaining: 100), now: scheduled)
        XCTAssertEqual(rollover.map(\.windowId), ["7d"])
        XCTAssertEqual(rollover.first?.reason, .newPeriod)
        XCTAssertEqual(rollover.first?.endedPeriodResetAt, t0 + 11 * self.day)
        XCTAssertFalse(rollover.first?.isVendorReset ?? true)
        XCTAssertFalse(rollover.first?.isPlanChange ?? true)
    }

    /// The live MiniMax history recorded a stale 9:00 AM deadline, then a correction to Nov 8 at 6:00 PM with the weekly balance unchanged at 73%.
    func testPassedMiniMaxDeadlineCorrectionWithUnchangedQuotaDoesNotAlertAndValidRolloverDoes() {
        var tracker = ResetAlarmTracker()
        func minimax(at observedAt: Date, resetAt: Date, remaining: Double) -> ResetAlarmObservation {
            ResetAlarmObservation(scope: "local", providerId: "minimax", providerTitle: "MiniMax",
                windowId: "local-mac:minimax:general:weekly", windowLabel: "7d", periodSeconds: 7 * day,
                resetAt: resetAt, remainingPercent: remaining, observedAt: observedAt)
        }

        let firstRead = t0
        let staleDeadline = firstRead + 25 * 60
        _ = tracker.process([minimax(at: firstRead, resetAt: staleDeadline, remaining: 73)], now: firstRead)

        let correctedRead = firstRead + 32 * 60
        let correctedDeadline = staleDeadline + 5 * day + 9 * hour
        let correction = tracker.process(
            [minimax(at: correctedRead, resetAt: correctedDeadline, remaining: 73)], now: correctedRead)

        XCTAssertTrue(correction.isEmpty, "a passed stale deadline corrected forward without quota restoration is not a new week")
        let key = ResetAlarmTracker.windowKey(scope: "local", providerId: "minimax", windowId: "local-mac:minimax:general:weekly")
        XCTAssertEqual(tracker.state.windows[key]?.periodResetAt, correctedDeadline)
        XCTAssertEqual(tracker.state.windows[key]?.lastRemaining, 73)

        let scheduled = correctedDeadline + 60
        let rollover = tracker.process(
            [minimax(at: scheduled, resetAt: scheduled + 7 * day, remaining: 100)], now: scheduled)
        XCTAssertEqual(rollover.map(\.windowId), ["local-mac:minimax:general:weekly"])
        XCTAssertEqual(rollover.first?.reason, .newPeriod)
        XCTAssertEqual(rollover.first?.endedPeriodResetAt, correctedDeadline)
    }

    func testPassedStaleWeeklyDeadlineAdoptsFlatAndSmallFluctuationsSilently() {
        for balance in [72.0, 73.0, 74.0] {
            var tracker = ResetAlarmTracker()
            let oldEnd = t0 + 25 * 60
            let nextEnd = oldEnd + 5 * day + 9 * hour
            _ = tracker.process(weekly(at: t0, resetAt: oldEnd, remaining: 72, provider: "minimax"), now: t0)
            let later = t0 + 32 * 60
            XCTAssertTrue(tracker.process(weekly(at: later, resetAt: nextEnd, remaining: balance, provider: "minimax"), now: later).isEmpty)
            let key = ResetAlarmTracker.windowKey(scope: "local", providerId: "minimax", windowId: "7d")
            XCTAssertEqual(tracker.state.windows[key]?.periodResetAt, nextEnd)
            XCTAssertEqual(tracker.state.windows[key]?.lastRemaining, balance)
            XCTAssertTrue(tracker.process(weekly(at: later + 60, resetAt: nextEnd, remaining: balance, provider: "minimax"), now: later + 60).isEmpty)
        }
    }

    func testFleetWeeklyFutureDeadlineCorrectionsNeverTreatSmallDriftAsMidwindowRestore() {
        for balance in [72.0, 73.0, 74.0] {
            var tracker = ResetAlarmTracker()
            let oldEnd = t0 + day
            func fleet(at time: Date, end: Date, value: Double) -> ResetAlarmObservation {
                ResetAlarmObservation(scope: "Mac.Jays.Services", providerId: "minimax", providerTitle: "MiniMax",
                    windowId: "7d", windowLabel: "7d", periodSeconds: 7 * day,
                    resetAt: end, remainingPercent: value, observedAt: time)
            }
            _ = tracker.process([fleet(at: t0, end: oldEnd, value: 72)], now: t0)
            let later = t0 + hour
            XCTAssertTrue(tracker.process([fleet(at: later, end: oldEnd + 5 * day, value: balance)], now: later).isEmpty)
            let key = ResetAlarmTracker.windowKey(scope: "Mac.Jays.Services", providerId: "minimax", windowId: "7d")
            XCTAssertEqual(tracker.state.windows[key]?.periodResetAt, oldEnd + 5 * day)
            XCTAssertEqual(tracker.state.windows[key]?.lastRemaining, balance)
        }
    }

    func testFlatFullQuotaStillReportsElapsedWeeklyAndCalendarMonthRollovers() {
        for (period, advance) in [(7 * day, 7 * day), (30 * day, 28 * day), (30 * day, 31 * day)] {
            var tracker = ResetAlarmTracker()
            let end = t0 + hour
            _ = tracker.process([reading("cadence", period: period, resetAt: end, remaining: 100, observedAt: t0)], now: t0)
            let later = end + 60
            let events = tracker.process([reading("cadence", period: period, resetAt: end + advance, remaining: 100, observedAt: later)], now: later)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.reason, .newPeriod)
        }
    }

    func testFiveHourFlatQuotaRolloverRetainsNearCapNotificationPolicy() {
        var tracker = ResetAlarmTracker()
        let end = t0 + hour
        _ = tracker.process([reading("5h", period: 5 * hour, resetAt: end, remaining: 10, observedAt: t0)], now: t0)
        let later = end + 60
        let events = tracker.process([reading("5h", period: 5 * hour, resetAt: end + 5 * hour, remaining: 10, observedAt: later)], now: later)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .newPeriod)
    }

    // MARK: The words

    func testAPlanChangeIsAnnouncedUnderItsOwnName() {
        let change = ResetAlarmEvent(scope: "local", providerId: "musecode", providerTitle: "Muse Code",
                                     windowId: "7d", windowLabel: "7d", periodSeconds: 7 * 86_400,
                                     endedPeriodResetAt: nil, remainingPercent: 75, reason: .planChange,
                                     isPlanChange: true)
        let content = ResetAlarmMessage.content(for: [change])
        XCTAssertEqual(content.title, "Likely Plan Change: Muse Code")
        XCTAssertEqual(content.body,
                       "The 7d window's quota rose to 75% mid-cycle."
                           + sentenceGap
                           + "More likely a plan change than a vendor reset.")
    }

    func testAVendorResetKeepsItsOwnNameWhenBothAreInOneNotification() {
        let vendor = ResetAlarmEvent(scope: "local", providerId: "musecode", providerTitle: "Muse Code",
                                     windowId: "5h", windowLabel: "5h", periodSeconds: 5 * 3_600,
                                     endedPeriodResetAt: nil, remainingPercent: 100,
                                     reason: .nearCap(minimumRemaining: 0), isVendorReset: true)
        let change = ResetAlarmEvent(scope: "local", providerId: "musecode", providerTitle: "Muse Code",
                                     windowId: "7d", windowLabel: "7d", periodSeconds: 7 * 86_400,
                                     endedPeriodResetAt: nil, remainingPercent: 75, reason: .planChange,
                                     isPlanChange: true)
        let content = ResetAlarmMessage.content(for: [vendor, change])
        XCTAssertEqual(content.title, "Vendor Reset: Muse Code")
        XCTAssertTrue(content.body.hasPrefix("The 5h and 7d windows received a vendor reset."))
    }

    /// The level decides the name, and the refresh cadence does not.  The
    /// detection of the rise has to be identical whether the owner looked once
    /// a minute or once an hour.
    func testTheNameIsTheSameAtEveryRefreshCadence() {
        for gap in [30.0, 300.0, 3_600.0] {
            for (level, isVendor) in [(100.0, true), (75.0, false)] {
                var tracker = ResetAlarmTracker()
                let weekEnd = t0 + 7 * self.day
                _ = tracker.process(weekly(at: t0, resetAt: weekEnd, remaining: 0), now: t0)
                let later = t0 + gap
                let events = tracker.process(weekly(at: later, resetAt: weekEnd, remaining: level), now: later)

                XCTAssertEqual(events.count, 1, "Gap of \(Int(gap))s at \(Int(level))% must still be reported.")
                XCTAssertEqual(events.first?.isVendorReset, isVendor, "Gap of \(Int(gap))s at \(Int(level))%.")
                XCTAssertEqual(events.first?.isPlanChange, !isVendor, "Gap of \(Int(gap))s at \(Int(level))%.")
            }
        }
    }
}
