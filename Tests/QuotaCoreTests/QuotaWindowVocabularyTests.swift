import XCTest
@testable import QuotaCore

final class QuotaWindowVocabularyTests: XCTestCase {
    func testStandardCadenceFromTokens() {
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "5h", label: ""), "5-hour")
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "7d", label: ""), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "1m", label: ""), "1-month")
    }

    /// An extra allowance names no period of its own.
    ///
    /// It joins the group of the one sibling that has a period,  and the sibling
    /// resolution is what does that.  The group lookup itself must not hand it a
    /// period,  or a bar that prints "7d" would be split from the sibling that
    /// prints the same token (Kody review 2026-10-21).
    func testAnExtraAllowanceHasNoGroupOfItsOwn() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(
                cadence: "Other limit",
                label: "Other limit",
                isExtraAllowance: true
            ),
            QuotaWindowVocabulary.otherLimit
        )
    }

    /// A canonical label names its period.
    ///
    /// The widget renders "7-day window",  "5-hour window" and "1-month window",
    /// and a bar whose label says one of them has to group with the bar that
    /// prints the same token,  or the two are split (Kody review 2026-10-21).
    func testACanonicalLabelNamesItsPeriod() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "7-day window"),
            QuotaWindowVocabulary.sevenDay
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "5-hour window"),
            QuotaWindowVocabulary.fiveHour
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "1-month window"),
            QuotaWindowVocabulary.oneMonth
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "1-day window"),
            QuotaWindowVocabulary.oneDay
        )
    }

    func testOpaqueAnthropicKeyMapsToOtherLimit() {
        let label = QuotaWindowVocabulary.windowLabel(windowToken: nil, existingLabel: "iguana_necktie", resetAt: nil, periodStart: nil)
        XCTAssertEqual(label, "Other limit window")
    }

    func testOpaqueKeyWithMonthlySpanMapsToOneMonth() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(30 * 86_400)
        let cadence = QuotaWindowVocabulary.standardCadence(
            windowToken: nil,
            label: "iguana_necktie",
            resetAt: end,
            periodStart: start
        )
        XCTAssertEqual(cadence, "1-month")
    }

    func testStripsModelParentheticalOnSanitize() {
        let window = QuotaWindow(
            id: "x",
            provider: "Claude",
            label: "5h window (Opus)",
            remainingPercent: 50,
            window: "5h",
            occurredAt: "2026-01-01T00:00:00Z"
        ).normalizedForExport()
        XCTAssertFalse(window.label.lowercased().contains("opus"))
        XCTAssertTrue(window.label.contains("5-hour"))
    }

    func testAntigravityPoolKeepsHead() {
        let label = QuotaWindowVocabulary.windowLabel(
            windowToken: "7d",
            existingLabel: "Gemini · Weekly",
            resetAt: nil,
            periodStart: nil
        )
        XCTAssertEqual(label, "Gemini · 7-day")
    }

    func testPopoverCaptionCompactUnits() {
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: "5h", label: "5-hour window"),
            "5h"
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: "7d", label: "7-day window"),
            "7d"
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: nil, label: "Additional tokens", isExtraAllowance: true),
            "+"
        )
    }

    func testExtraAllowanceLabelDetection() {
        XCTAssertTrue(QuotaWindowVocabulary.isExtraAllowanceLabel("Additional additional tokens"))
        XCTAssertTrue(QuotaWindowVocabulary.isExtraAllowanceLabel("plan + extra"))
    }

    func testMuseAssistWeeklyAndExtraMetersAreClassifiedSeparately() {
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistWeekly(
            providerKey: "muse-assist",
            windowToken: "168h",
            label: "Free weekly limit"
        ))
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist",
            windowToken: nil,
            label: "Additional tokens"
        ))
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist",
            windowToken: "8h",
            label: "8h window"
        ))
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistWeekly(
            providerKey: "openai",
            windowToken: "168h",
            label: "Weekly"
        ))
    }

    // MARK: - The line a capped plan says

    /// The cap line is shared by the Mac's menu-bar window, its PiP and the
    /// phone companion, so one plan reads the same on every surface.
    func testAtCapSummaryNamesTheCapAndCountsDownToItsReset() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reset = now.addingTimeInterval(37 * 3_600 + 30 * 60)
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "7-day", resetAt: reset, now: now),
                       "7-day cap resets in 1d 13h")
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "5-hour", resetAt: now.addingTimeInterval(3_600), now: now),
                       "5-hour cap resets in 1h")
    }

    /// A cap with no clock still says so, and a reset that has already passed
    /// does not become "resets in due".
    func testAtCapSummaryWithoutAUsableCountdownJustNamesTheCap() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "7-day", resetAt: nil, now: now),
                       "7-day cap")
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "7-day", resetAt: now.addingTimeInterval(-60), now: now),
                       "7-day cap")
    }

    /// The countdown skips a unit that is zero, so it never reads "1d 0h".
    func testResetCountdownSkipsZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(86_400), now: now), "1d")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(2 * 3_600 + 42 * 60), now: now), "2h 42m")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(nil, now: now), "")
    }

    /// A window that already carries the canonical cadence keeps it; anything
    /// else is re-derived, so an at-cap line never says "Other limit" when the
    /// window meant something narrower.
    func testAtCapCadenceKeepsTheCanonicalName() {
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "7-day"), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "5-hour"), "5-hour")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "weekly"), "7-day")
    }

    // MARK: - The freshness rule

    /// Owner 2026-10-22: the xAI row read "7-day cap" while the sidebar beside
    /// it read 96%.  The number rule filtered on freshness and the cap rule did
    /// not, so a window that reported an exhausted allowance days ago still
    /// bound the cap.
    ///
    /// These tests pin the one threshold every surface uses, so the Mac's
    /// dashboard, the cap rule, the widget and the phone age a reading the same
    /// way.
    func testAReadingYoungerThanHalfAnHourIsFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(QuotaFreshnessRule.isReadingRecent(observedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(QuotaFreshnessRule.isReadingRecent(observedAt: now, now: now))
    }

    func testAReadingOlderThanHalfAnHourIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = now.addingTimeInterval(-(QuotaFreshnessRule.staleAfter + 1))
        XCTAssertFalse(QuotaFreshnessRule.isReadingRecent(observedAt: stale, now: now))
    }

    func testAReadingWithNoTimestampIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(QuotaFreshnessRule.isReadingRecent(observedAt: nil, now: now))
    }

    func testAReadingFromBeyondTheFutureSkewIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ahead = now.addingTimeInterval(QuotaFreshnessRule.maximumFutureSkew + 60)
        XCTAssertFalse(QuotaFreshnessRule.isReadingRecent(observedAt: ahead, now: now))
    }

    /// A window whose reset has passed is waiting for a fresh reading, so its
    /// old number says nothing about the plan now.
    func testAWindowWhoseResetHasPassedIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(QuotaFreshnessRule.isFresh(observedAt: now.addingTimeInterval(-60),
                                                  resetAt: now.addingTimeInterval(-1),
                                                  now: now))
        XCTAssertTrue(QuotaFreshnessRule.isFresh(observedAt: now.addingTimeInterval(-60),
                                                 resetAt: now.addingTimeInterval(3600),
                                                 now: now))
    }

    /// The Mac's own snapshot asks the shared rule, so the dashboard and the cap
    /// rule can never read one window differently.
    func testTheMacSnapshotAsksTheSharedRule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let iso = ISO8601DateFormatter()
        let window = QuotaWindow(
            id: "xai:subscription",
            provider: "xAI",
            providerKey: "xai",
            providerLabel: "xAI",
            label: "7-day window",
            remainingPercent: 96,
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "xai")
        XCTAssertTrue(QuotaWindowSnapshot(window: window, now: now).isFresh)

        let stale = QuotaWindow(
            id: "xai:subscription",
            provider: "xAI",
            providerKey: "xai",
            providerLabel: "xAI",
            label: "1w window",
            remainingPercent: 0,
            isExhausted: true,
            window: "1w",
            occurredAt: iso.string(from: now.addingTimeInterval(-5 * 86_400)),
            source: "xai")
        XCTAssertFalse(QuotaWindowSnapshot(window: stale, now: now).isFresh)
    }

    // MARK: - The dead copy rule

    /// Owner 2026-10-23: the xAI row showed two 7-day windows at 0% with a
    /// "due" caption while Grok, Cursor and Grok Bot showed the same weekly
    /// allowance at 91% with a reset on 2026-10-29.  This Mac reads no xAI
    /// quota locally, so the fleet fallback filled the xAI row with copies of
    /// a period that ended days earlier, and the app printed them as live
    /// readings.
    ///
    /// A copy whose period has ended and whose reading is no longer recent
    /// carries no live information, so it is a dead copy.
    func testACopyOfAPeriodThatEndedIsADeadCopy() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // The live copy of the same pool:  observed a minute ago, with its
        // reset still ahead.
        XCTAssertFalse(QuotaFreshnessRule.isDeadCopy(observedAt: now.addingTimeInterval(-60),
                                                      resetAt: now.addingTimeInterval(6 * 86_400),
                                                      now: now))
        // The dead copy:  the reset passed days ago and the reading is old.
        XCTAssertTrue(QuotaFreshnessRule.isDeadCopy(observedAt: now.addingTimeInterval(-6 * 86_400),
                                                     resetAt: now.addingTimeInterval(-86_400),
                                                     now: now))
        // A reading with no timestamp cannot be believed, but it is not a dead
        // copy either:  a window with no observation is unverified, and an
        // unverified window is never thrown away.  The Mac's decoder maps an
        // absent `occurredAt` to "", so a payload without a timestamp must keep
        // its row.
        XCTAssertFalse(QuotaFreshnessRule.isDeadCopy(observedAt: nil,
                                                      resetAt: now.addingTimeInterval(-86_400),
                                                      now: now))
        // A window with no reset clock has not expired, so it stays.
        XCTAssertFalse(QuotaFreshnessRule.isDeadCopy(observedAt: now.addingTimeInterval(-6 * 86_400),
                                                      resetAt: nil,
                                                      now: now))
        // A window still inside its period is a reading whatever its age.
        XCTAssertFalse(QuotaFreshnessRule.isDeadCopy(observedAt: now.addingTimeInterval(-6 * 86_400),
                                                      resetAt: now.addingTimeInterval(6 * 86_400),
                                                      now: now))
    }

    /// A period that rolls over must not blank the row beside it:  a window
    /// whose reset passed moments ago was observed moments ago as well, so it
    /// is still a reading and it keeps its `due` caption.
    func testAWindowWhoseResetJustPassedIsNotADeadCopy() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(QuotaFreshnessRule.isDeadCopy(observedAt: now.addingTimeInterval(-5),
                                                      resetAt: now.addingTimeInterval(-1),
                                                      now: now))
    }

    // MARK: - Whose reading is this

    /// The one test every surface asks to tell this device's own reading from
    /// a copy of another machine's.  The phone and the widget get their
    /// windows straight from the server, so they have no other way to ask.
    func testTheOwnDeviceWindowTestTellsAnOwnReadingFromACopy() {
        // The prefix this Mac's own windows carry.
        XCTAssertTrue(QuotaWindowVocabulary.isOwnDeviceWindow(id: "local-mac:xai:subscription",
                                                              source: nil,
                                                              machine: nil,
                                                              producerInstanceId: nil),
                      "a window this Mac read is its own reading")
        // A window that names a producer instance belongs to somebody.
        XCTAssertFalse(QuotaWindowVocabulary.isOwnDeviceWindow(id: "xai:subscription",
                                                               source: "CodeCaps",
                                                               machine: nil,
                                                               producerInstanceId: "other-mac"),
                       "a window that names a producer instance is a copy")
        // A window that names a machine belongs to somebody.
        XCTAssertFalse(QuotaWindowVocabulary.isOwnDeviceWindow(id: "xai:subscription",
                                                               source: "CodeCaps",
                                                               machine: "Other Mac",
                                                               producerInstanceId: nil),
                       "a window that names a machine is a copy")
        // A window that names neither and comes from this app is this device's
        // own push coming back from the server.
        XCTAssertTrue(QuotaWindowVocabulary.isOwnDeviceWindow(id: "xai:subscription",
                                                             source: "CodeCaps",
                                                             machine: nil,
                                                             producerInstanceId: nil),
                      "a window that names neither and comes from this app is its own push")
        // Somebody else's reader is a copy.
        XCTAssertFalse(QuotaWindowVocabulary.isOwnDeviceWindow(id: "xai:subscription",
                                                               source: "antigravity-usage",
                                                               machine: nil,
                                                               producerInstanceId: nil),
                       "a window from another reader is a copy")
    }
}
