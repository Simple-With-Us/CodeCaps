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

        XCTAssertTrue(events.allSatisfy { !$0.isVendorReset },
                      "a window with no readable percentage cannot claim a vendor reset")
        XCTAssertTrue(events.allSatisfy { !$0.isPlanChange })
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
