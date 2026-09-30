import XCTest
@testable import CodeCaps
import QuotaCore

/// Pins Glance popover layout helpers so future refactors of `GlanceRow` cannot
/// silently change the visible countdown format and trip an owner who has
/// learned what "5h 12m" or "12h 30m" means at a glance.
///
/// SwiftUI view bodies are not exercised directly (the codebase uses plain
/// XCTest, not ViewInspector).  The free helper that produces the trailing
/// column's countdown is the surface that actually drives the row's text and
/// that the popover depends on for every row, so it is the right thing to
/// lock down.
final class GlanceRowTests: XCTestCase {
    func testCountdownReturnsEmptyStringForNilReset() {
        let result = glanceResetCountdown(nil, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result, "")
    }

    func testCountdownReturnsDueForPastReset() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(-60)
        XCTAssertEqual(glanceResetCountdown(reset, now: now), "due")
    }

    func testCountdownRoundsUpToWholeMinute() {
        // The popover shows time in whole minutes; any sub-minute remainder
        // rounds up so a window with 30.4s left reads "1m", not "0m".
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(30)
        XCTAssertEqual(glanceResetCountdown(reset, now: now), "1m")
    }

    func testCountdownFormatSwitchesFromMinutesToHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let in59min = now.addingTimeInterval(59 * 60)
        let in60min = now.addingTimeInterval(60 * 60)
        let in61min = now.addingTimeInterval(61 * 60)
        XCTAssertEqual(glanceResetCountdown(in59min, now: now), "59m")
        XCTAssertEqual(glanceResetCountdown(in60min, now: now), "1h 0m")
        XCTAssertEqual(glanceResetCountdown(in61min, now: now), "1h 1m")
    }

    func testCountdownFormatSwitchesFromHoursToDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let daySeconds: TimeInterval = 24 * 60 * 60
        let in23h59m = now.addingTimeInterval(23 * 60 * 60 + 59 * 60)
        let in24h = now.addingTimeInterval(daySeconds)
        let in25h = now.addingTimeInterval(daySeconds + 60 * 60)
        XCTAssertEqual(glanceResetCountdown(in23h59m, now: now), "23h 59m")
        XCTAssertEqual(glanceResetCountdown(in24h, now: now), "1d 0h")
        XCTAssertEqual(glanceResetCountdown(in25h, now: now), "1d 1h")
    }

    func testCountdownIncludesMinutesForWeeklyWhenNonZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let in2d5h30m = now.addingTimeInterval(2 * 86_400 + 5 * 3_600 + 30 * 60)
        XCTAssertEqual(glanceResetCountdown(in2d5h30m, now: now), "2d 5h 30m")
    }

    func testCountdownFitsInTrailingColumnForCodepath() {
        // The trailing column on the popover is fixed at 64pt wide.  Any
        // countdown value that would clip in that column is a layout bug;
        // a regression here is a regression of the PR-#38 width bump.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let values: [String] = [
            glanceResetCountdown(now.addingTimeInterval(60), now: now),
            glanceResetCountdown(now.addingTimeInterval(60 * 60 + 50 * 60), now: now),
            glanceResetCountdown(now.addingTimeInterval(2 * 24 * 60 * 60 + 5 * 60 * 60), now: now),
        ]
        for value in values {
            // Five characters is the most the column has been shown to fit
            // in practice after the widen; longer strings have already been
            // observed to clip in the screenshot that drove PR #38.
            XCTAssertLessThanOrEqual(value.count, 6,
                "countdown '\(value)' is longer than the 64pt trailing column can render")
        }
    }
}

// MARK: - The two meters a compact row carries

/// Pins the 2026-09-29 widen: the popover shows the short (4-5hr) and the long
/// (weekly/monthly) quota for every platform on the row itself, so nothing has
/// to be expanded to see a second cadence.
///
/// The failure this guards against is specifically a row that quietly renders
/// ONE meter — a selector that returns the driving window twice looks correct
/// in a snapshot and is exactly the "half the truth" layout it replaced.
final class GlanceMeterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Helpers

    private func makeWindow(
        id: String,
        label: String,
        token: String? = nil,
        remaining: Double? = 50,
        resetIn: TimeInterval? = nil,
        provider: String = "anthropic"
    ) -> QuotaWindowSnapshot {
        let iso = ISO8601DateFormatter()
        return QuotaWindowSnapshot(window: QuotaWindow(
            id: id,
            provider: provider,
            providerKey: provider,
            providerLabel: provider,
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now)), now: now)
    }

    /// A Claude-shaped 5h + weekly row: the exact pair the owner asked to see
    /// at once, with the five-hour window deliberately healthier than the
    /// weekly so a selector that just took "closest to cap" twice would fail.
    private func claudeRow() -> DisplaySection {
        makeRow([
            makeWindow(id: "session", label: "5h window", token: "5h", remaining: 92, resetIn: 3 * 3600),
            makeWindow(id: "weekly", label: "7d window", token: "168h", remaining: 11, resetIn: 4 * 86_400),
        ])
    }

    private func makeRow(_ windows: [QuotaWindowSnapshot], masked: Set<String> = []) -> DisplaySection {
        DisplaySection(
            id: "anthropic",
            providerKey: "anthropic",
            title: "Claude",
            platformTitle: "Claude",
            section: QuotaPlatformSection(
                providerKey: "anthropic",
                providerLabel: "Claude",
                via: nil,
                expected: true,
                windows: windows),
            poolKey: nil,
            remainingPercent: windows.compactMap(\.remainingPercent).min(),
            resetAt: windows.compactMap(\.resetAt).min(),
            maskedWindowIds: masked)
    }

    // MARK: Layout

    func testTwoMeterRowFitsInsideThePopoverWidth() {
        // The whole point of the widen: two meters plus the title, the reset
        // countdown and the chevron, with the gutters, have to fit the frame
        // the popover actually opens at.  If a column grows past this, the
        // footer clips "Open CodeCaps ⌘1" the way the old 360pt width did.
        XCTAssertLessThanOrEqual(Metrics.glanceRowIntrinsicWidth, Metrics.glanceWidth,
            "the two-meter row is wider than the popover it renders in")
    }

    func testWidenedPopoverIsStillNarrowEnoughForAModestScreen() {
        // 1280pt was the narrowest display this app has been used on.  The
        // popover must not cover a useful share of it.
        XCTAssertLessThan(Metrics.glanceWidth, 1280 * 0.5)
    }

    func testMeterCaptionAlwaysFitsTheCaptionColumn() {
        // The caption column is 26pt at 9pt type, which is about five
        // characters.  A caption that outgrows it would push the two meters
        // out of alignment with each other.
        let tokens = ["5h", "5hr", "300m", "168h", "10080m", "weekly", "1w", "2w",
                      "43200m", "monthly", "24h", "daily", "3h", "session", "fast",
                      "plan", "", "1800s", "1.5h"]
        for token in tokens {
            let caption = glanceMeterCaption(makeWindow(id: token, label: "\(token) window", token: token))
            XCTAssertLessThanOrEqual(caption.count, 5,
                "caption '\(caption)' (token '\(token)') is too wide for the meter caption column")
        }
    }

    // MARK: Pair selection

    func testFiveHourAndWeeklyPairOntoOppositeMeters() {
        let pair = glanceMeterPair(for: claudeRow(), now: now)
        XCTAssertEqual(pair.short?.window.id, "session")
        XCTAssertEqual(pair.long?.window.id, "weekly")
    }

    func testPairNeverReturnsTheSameWindowTwice() {
        // The regression this exists for: a selector that resolves both slots
        // to the driving window renders one meter duplicated and the owner
        // still cannot see the weekly cap.
        for windows in [
            [makeWindow(id: "a", label: "5h window", token: "5h"), makeWindow(id: "b", label: "7d window", token: "weekly")],
            [makeWindow(id: "a", label: "3h window", token: "3h"), makeWindow(id: "b", label: "24h window", token: "24h")],
            [makeWindow(id: "a", label: "plan", remaining: nil), makeWindow(id: "b", label: "plan", remaining: nil)],
        ] {
            let pair = glanceMeterPair(for: makeRow(windows), now: now)
            XCTAssertNotNil(pair.long, "a two-window row must fill the second meter")
            if let long = pair.long {
                XCTAssertNotEqual(long.window.id, pair.short?.window.id,
                    "the same window cannot occupy both meters")
            }
        }
    }

    func testPairPicksByCadenceRatherThanByWhichWindowIsWorse() {
        // The weekly is at 11% and the five-hour at 92%.  A row that took the
        // lowest percentage twice would show the weekly in both slots and hide
        // the five-hour entirely.
        let pair = glanceMeterPair(for: claudeRow(), now: now)
        XCTAssertEqual(pair.short?.window.remainingPercent, 92)
        XCTAssertEqual(pair.long?.window.remainingPercent, 11)
    }

    func testPairSkipsAnAntigravityMaskedFiveHourWindow() {
        // Antigravity masks the 5h percentage when the weekly cap is spent,
        // because the 5h reading must not be believed.  A masked window in a
        // meter is worse than no meter.
        let row = makeRow([
            makeWindow(id: "5h", label: "Third-Party · 5-hour", token: "5h", remaining: 80),
            makeWindow(id: "weekly", label: "Third-Party · Weekly", token: "weekly", remaining: 0),
        ], masked: ["5h"])
        let pair = glanceMeterPair(for: row, now: now)
        XCTAssertEqual(pair.short?.window.id, "weekly")
    }

    func testPairFallsBackToTheDrivingWindowWhenEveryWindowIsMasked() {
        let row = makeRow([
            makeWindow(id: "5h", label: "Gemini · 5-hour", token: "5h", remaining: 80),
            makeWindow(id: "weekly", label: "Gemini · Weekly", token: "weekly", remaining: 0),
        ], masked: ["5h", "weekly"])
        let pair = glanceMeterPair(for: row, now: now)
        XCTAssertNotNil(pair.short, "a fully masked row must still render something")
    }

    func testSingleCadenceProviderFillsTheFirstMeterOnly() {
        // Grok Bot publishes one weekly meter.  It must land in the first slot
        // — never the second, and never both.
        let pair = glanceMeterPair(for: makeRow([
            makeWindow(id: "grokbot", label: "Grok Bot weekly", token: "weekly", remaining: 40)
        ]), now: now)
        XCTAssertEqual(pair.short?.window.id, "grokbot")
        XCTAssertNil(pair.long)
    }

    func testPairIsEmptyForARowWithNoWindows() {
        let pair = glanceMeterPair(for: makeRow([]), now: now)
        XCTAssertNil(pair.short)
        XCTAssertNil(pair.long)
    }

    func testSupplementaryVideoQuotaNeverOccupiesAMeter() {
        // MiniMax's video allowance is supplementary to the coding
        // subscription; showing it in a meter would displace a real cap.
        let video = QuotaWindowSnapshot(window: QuotaWindow(
            id: "video",
            provider: "MiniMax",
            providerKey: "minimax",
            label: "Video generation",
            remainingPercent: 30,
            remainingUnknown: false,
            window: "5h",
            occurredAt: ISO8601DateFormatter().string(from: now)), now: now)
        let pair = glanceMeterPair(for: makeRow([
            video,
            makeWindow(id: "code", label: "MiniMax Code (5h window)", token: "5h", remaining: 70),
        ]), now: now)
        XCTAssertEqual(pair.short?.window.id, "code")
    }

    // MARK: Captions

    func testWeeklyTokensCaptionAsSevenDays() {
        // Antigravity's pool labels are long ("Third-Party · Weekly"), so the
        // caption has to come from the cadence token, and a weekly window has
        // to read the same way next to a 5h one.
        for token in ["weekly", "1w", "168h", "10080m"] {
            XCTAssertEqual(glanceMeterCaption(makeWindow(id: token, label: "Third-Party · Weekly", token: token)), "7d",
                "token '\(token)' should caption as 7d")
        }
    }

    func testFiveHourTokensCaptionAsFiveHours() {
        for token in ["5h", "5hr", "300m"] {
            XCTAssertEqual(glanceMeterCaption(makeWindow(id: token, label: "Gemini · 5-hour", token: token)), "5h",
                "token '\(token)' should caption as 5h")
        }
    }

    func testMonthlyTokensCaptionAsOneMonth() {
        // Owner ruling 2026-09-30: a month reads "1m" on every row, never
        // "30d" and never "Plan".
        for token in ["monthly", "30d", "31d", "28d", "43200m", "month", "billing-cycle"] {
            XCTAssertEqual(glanceMeterCaption(makeWindow(id: token, label: "Plan", token: token)), "1m",
                "token '\(token)' should caption as 1m")
        }
    }

    func testCursorIncludedPlanCaptionsAsOneMonth() {
        // Cursor's plan resets with its monthly billing cycle.  Its reader tags
        // the window "billing-cycle"; the unknown-reading fallback has no token
        // at all, and both used to caption as "Plan".
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "c", label: "Included plan", token: "billing-cycle",
                                                     provider: "cursor")), "1m")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "c", label: "Included plan", token: nil,
                                                     provider: "cursor")), "1m")
    }

    func testTokenlessWindowCaptionsFromItsLabelThenAsPlan() {
        // Kimi's plan quota arrives with no cadence token and no known period,
        // so it still says "Plan" rather than guessing a month.
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "k", label: "Plan quota", token: nil)), "Plan")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "m", label: "Monthly allowance", token: nil)), "1m")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "u", label: "Something else", token: nil)), "Quota")
    }

    func testCompactConsoleNameSaysOneMonthForMonthlyWindows() {
        XCTAssertEqual(compactWindowName("Included plan"), "1m")
        XCTAssertEqual(compactWindowName("Monthly window"), "1m")
        XCTAssertEqual(compactWindowName("Billing cycle"), "1m")
        XCTAssertEqual(compactWindowName("5-hour window"), "5h")
    }

    func testCaptionFallsBackToTheLabelWhenTheTokenIsNotADuration() {
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "x", label: "Third-Party Models · Weekly", token: "shared")), "7d")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "y", label: "Gemini Models · 5-hour", token: "shared")), "5h")
    }

    // MARK: Cadence

    func testCadenceReadsTheWindowTokenWhenPresent() {
        XCTAssertEqual(glanceCadence(makeWindow(id: "a", label: "l", token: "5h"), now: now), .short)
        XCTAssertEqual(glanceCadence(makeWindow(id: "b", label: "l", token: "24h"), now: now), .long)
        XCTAssertEqual(glanceCadence(makeWindow(id: "c", label: "l", token: "weekly"), now: now), .long)
        XCTAssertEqual(glanceCadence(makeWindow(id: "d", label: "l", token: "session"), now: now), .short)
    }

    func testCadenceFallsBackToHowLongUntilReset() {
        // A window with no cadence token is still classifiable by how far off
        // its reset is, which is the only signal a plan meter gives.
        let soon = makeWindow(id: "s", label: "l", token: nil, resetIn: 3 * 3600)
        let later = makeWindow(id: "l", label: "l", token: nil, resetIn: 5 * 86_400)
        XCTAssertEqual(glanceCadence(soon, now: now), .short)
        XCTAssertEqual(glanceCadence(later, now: now), .long)
    }

    func testCadenceTreatsATokenlessWindowWithNoResetAsLong() {
        // A subscription-wide allowance with neither a cadence nor a reset is
        // the long side of the pair far more often than the short one.
        XCTAssertEqual(glanceCadence(makeWindow(id: "u", label: "Included plan", token: nil), now: now), .long)
    }

    // MARK: Pacing Marker

    func testElapsedFractionForFiveHourWindow() {
        // 5-hour window with 2.5 hours remaining -> 50% elapsed
        let window5hHalf = makeWindow(id: "5h", label: "5h window", token: "5h", resetIn: 2.5 * 3_600)
        let fractionHalf = window5hHalf.elapsedFraction(now: now)
        XCTAssertNotNil(fractionHalf)
        if let fractionHalf {
            XCTAssertEqual(fractionHalf, 0.5, accuracy: 0.01)
        }

        // 5-hour window with 5 hours remaining -> 0% elapsed
        let window5hFull = makeWindow(id: "5h", label: "5h window", token: "5h", resetIn: 5.0 * 3_600)
        let fractionFull = window5hFull.elapsedFraction(now: now)
        XCTAssertNotNil(fractionFull)
        if let fractionFull {
            XCTAssertEqual(fractionFull, 0.0, accuracy: 0.01)
        }

        // 5-hour window with 0 hours remaining -> 100% elapsed
        let window5hZero = makeWindow(id: "5h", label: "5h window", token: "5h", resetIn: 0)
        let fractionZero = window5hZero.elapsedFraction(now: now)
        XCTAssertNotNil(fractionZero)
        if let fractionZero {
            XCTAssertEqual(fractionZero, 1.0, accuracy: 0.01)
        }
    }

    func testElapsedFractionForWeeklyWindow() {
        // 7-day window with 3.5 days remaining -> 50% elapsed
        let window7dHalf = makeWindow(id: "7d", label: "Weekly window", token: "weekly", resetIn: 3.5 * 86_400)
        let fractionHalf = window7dHalf.elapsedFraction(now: now)
        XCTAssertNotNil(fractionHalf)
        if let fractionHalf {
            XCTAssertEqual(fractionHalf, 0.5, accuracy: 0.01)
        }
    }

    func testElapsedFractionNilWhenResetOrDurationUnknown() {
        let windowNoReset = makeWindow(id: "x", label: "No reset", token: "5h", resetIn: nil)
        XCTAssertNil(windowNoReset.elapsedFraction(now: now))

        let windowNoDuration = makeWindow(id: "y", label: "Unknown", token: nil, resetIn: 3_600)
        XCTAssertNil(windowNoDuration.elapsedFraction(now: now))
    }
}
