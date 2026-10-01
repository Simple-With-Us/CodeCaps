import Foundation
@testable import QuotaCore
import XCTest

/// Pins the math behind the two-segment quota bar and its elapsed-time marker:
/// which period a window covers, where it started, how far through it we are,
/// and how wide the red and green segments are.  The SwiftUI layer only draws
/// what these return, so these are the tests that stand in for the picture.
final class QuotaBarMetricsTests: XCTestCase {
    /// A fixed calendar so month arithmetic never depends on the machine's time
    /// zone or locale.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func snapshot(
        token: String?,
        label: String = "Window",
        remaining: Double? = 50,
        reset: String?,
        periodStart: String? = nil,
        now: Date
    ) -> QuotaWindowSnapshot {
        let iso = ISO8601DateFormatter()
        return QuotaWindowSnapshot(window: QuotaWindow(
            id: "w",
            provider: "Cursor",
            providerKey: "cursor",
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: reset,
            window: token,
            occurredAt: iso.string(from: now),
            periodStart: periodStart), now: now)
    }

    // MARK: Used and remaining

    func testUsedIsOneHundredMinusRemaining() throws {
        let metrics = QuotaBarMetrics(remainingPercent: 85, elapsedFraction: nil)
        XCTAssertEqual(try XCTUnwrap(metrics.usedFraction), 0.15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metrics.remainingPercent), 85, accuracy: 1e-9)
        XCTAssertEqual(metrics.usedPercentRounded, 15)
        XCTAssertEqual(metrics.remainingPercentRounded, 85)
    }

    func testZeroRemainingIsAllRedAndFullRemainingIsAllGreen() throws {
        let empty = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 0, elapsedFraction: nil).segmentWidths(in: 50))
        XCTAssertEqual(empty.used, 50, accuracy: 1e-9)
        XCTAssertEqual(empty.remaining, 0, accuracy: 1e-9)

        let full = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: nil).segmentWidths(in: 50))
        XCTAssertEqual(full.used, 0, accuracy: 1e-9)
        XCTAssertEqual(full.remaining, 50, accuracy: 1e-9)
    }

    func testTheTwoSegmentsAlwaysFillTheBarWithNoSeam() throws {
        for remaining in stride(from: 0.0, through: 100.0, by: 7.3) {
            for width in [50.0, 123.4, 300.0] {
                let widths = try XCTUnwrap(QuotaBarMetrics(remainingPercent: remaining, elapsedFraction: nil)
                    .segmentWidths(in: width))
                XCTAssertEqual(widths.used + widths.remaining, width, accuracy: 1e-9)
                XCTAssertGreaterThanOrEqual(widths.used, 0)
                XCTAssertGreaterThanOrEqual(widths.remaining, 0)
            }
        }
    }

    func testTheRedSegmentIsTheShareUsedFromTheLeft() throws {
        let widths = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 15, elapsedFraction: nil).segmentWidths(in: 200))
        XCTAssertEqual(widths.used, 170, accuracy: 1e-9)
        XCTAssertEqual(widths.remaining, 30, accuracy: 1e-9)
    }

    func testAnUnknownReadingHasNoSegments() {
        let metrics = QuotaBarMetrics(remainingPercent: nil, elapsedFraction: 0.5)
        XCTAssertFalse(metrics.hasReading)
        XCTAssertNil(metrics.usedFraction)
        XCTAssertNil(metrics.segmentWidths(in: 50))
        // The marker is about time, not the reading, so it survives.
        XCTAssertNotNil(layout(metrics, in: 50))
    }

    func testOutOfRangeAndNonFiniteInputsAreBounded() {
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: 140, elapsedFraction: nil).remainingPercent, 100)
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: -5, elapsedFraction: nil).remainingPercent, 0)
        XCTAssertNil(QuotaBarMetrics(remainingPercent: .nan, elapsedFraction: nil).remainingPercent)
        XCTAssertNil(QuotaBarMetrics(remainingPercent: .infinity, elapsedFraction: nil).remainingPercent)
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: 3).elapsedFraction, 1)
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: -1).elapsedFraction, 0)
        XCTAssertNil(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: .nan).elapsedFraction)
    }

    // MARK: Marker position

    /// The marker's layout on a bar as Glance draws it: 6pt thick, a 2pt
    /// marker, a 1pt halo.
    private func layout(_ metrics: QuotaBarMetrics, in width: Double, barHeight: Double = 6) -> QuotaMarkerLayout? {
        metrics.markerLayout(in: width, barHeight: barHeight, markerWidth: 2, haloPadding: 1)
    }

    func testMarkerSitsAtTheElapsedFractionFromTheLeft() throws {
        for fraction in [0.1, 0.5, 0.9] {
            let placed = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: fraction), in: 100))
            XCTAssertEqual(placed.center, 100 * fraction, accuracy: 1e-9)
        }
    }

    func testMarkerStaysInsideBothEndsOfTheBarAndTheHaloIsCutOffAtThem() throws {
        let start = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: 0), in: 50))
        XCTAssertEqual(start.center, 1, "the 2pt marker stands flush with the left end")
        XCTAssertEqual(start.haloStart, 0, "and its halo is cut off at the end rather than hanging past it")
        XCTAssertEqual(start.haloEnd, 3)
        let end = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: 1), in: 50))
        XCTAssertEqual(end.center, 49)
        XCTAssertEqual(end.haloStart, 47)
        XCTAssertEqual(end.haloEnd, 50)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
            let placed = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: fraction), in: 50))
            XCTAssertGreaterThanOrEqual(placed.center - 1, 0, "elapsed \(fraction)")
            XCTAssertLessThanOrEqual(placed.center + 1, 50, "elapsed \(fraction)")
            XCTAssertGreaterThanOrEqual(placed.haloStart, 0, "elapsed \(fraction)")
            XCTAssertLessThanOrEqual(placed.haloEnd, 50, "elapsed \(fraction)")
            XCTAssertLessThanOrEqual(placed.haloStart, placed.center - 1, "the marker is inside its halo")
            XCTAssertGreaterThanOrEqual(placed.haloEnd, placed.center + 1, "the marker is inside its halo")
        }
    }

    func testNoSliverOfBarHangsOffTheMarker() throws {
        // Codex's 5h window at 100% with the period 6% elapsed: the marker was
        // 2pt in, which left a small "c" of bar to the left of it.  On either
        // side of the marker there is now no bar at all, or at least a whole
        // cap (half the bar's thickness).
        let barHeight = 6.0
        let cap = barHeight / 2
        for fraction in stride(from: 0.0, through: 1.0, by: 0.005) {
            let placed = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: fraction),
                                              in: 50, barHeight: barHeight))
            for leftover in [placed.center - 1, 50 - (placed.center + 1)] {
                XCTAssertTrue(leftover == 0 || leftover >= cap,
                              "elapsed \(fraction): \(leftover)pt of bar would hang off the marker")
            }
        }
        // 6% elapsed: the marker moves the 2pt to the bar's end.
        let early = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: 19.0 / 300), in: 50))
        XCTAssertEqual(early.center, 1)
        XCTAssertEqual(early.haloStart, 0)
        let late = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: 0.97), in: 50))
        XCTAssertEqual(late.center, 49)
        XCTAssertEqual(late.haloEnd, 50)
        // A stub of a whole cap or more is a real end of the bar: the marker stays put.
        let kept = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: 0.12), in: 50))
        XCTAssertEqual(kept.center, 6, accuracy: 1e-9)
        // Mid-bar the halo is the marker plus its padding.
        let middle = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: 0.5), in: 50))
        XCTAssertEqual(middle.haloWidth, 4)
        XCTAssertEqual(middle.center, 25)
    }

    func testTheMarkerNeverMovesMoreThanACapFromWhereTheTimeIs() throws {
        let barHeight = 6.0
        for width in [30.0, 50.0, 100.0, 240.0] {
            for fraction in stride(from: 0.0, through: 1.0, by: 0.005) {
                let placed = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: fraction),
                                                  in: width, barHeight: barHeight))
                let clamped = min(max(width * fraction, 1), width - 1)
                XCTAssertLessThan(abs(placed.center - clamped), barHeight / 2,
                                  "width \(width), elapsed \(fraction)")
            }
        }
    }

    func testTheLayoutNeverDependsOnTheReadingSoNoShareCanBeHiddenByIt() throws {
        // The marker is placed from the time alone and the bar is never trimmed
        // around it: the red and green a bar draws are the share it reads, at
        // every elapsed fraction.  (A trim around the marker once erased the
        // red of a bar that read 90% remaining with the period 14% elapsed.)
        for fraction in stride(from: 0.0, through: 1.0, by: 0.01) {
            let reference = layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: fraction), in: 50)
            for remaining in 1...99 {
                let metrics = QuotaBarMetrics(remainingPercent: Double(remaining), elapsedFraction: fraction)
                XCTAssertEqual(layout(metrics, in: 50), reference, "remaining \(remaining), elapsed \(fraction)")
                let widths = try XCTUnwrap(metrics.segmentWidths(in: 50))
                XCTAssertEqual(widths.used, 50 * Double(100 - remaining) / 100, accuracy: 1e-9,
                               "the red is the share used at \(remaining)% remaining")
                XCTAssertEqual(widths.remaining, 50 * Double(remaining) / 100, accuracy: 1e-9,
                               "the green is the share left at \(remaining)% remaining")
            }
        }
    }

    func testABarTooShortForAMarkerAndTwoCapsKeepsTheMarkerWhereTheTimeIs() throws {
        // 7pt cannot hold a 2pt marker with a 3pt cap either side, so nothing
        // moves: 30% of 7pt is 2.1pt, not the 1pt a snap would give.
        let tiny = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: 0.3), in: 7))
        XCTAssertEqual(tiny.center, 2.1, accuracy: 1e-9)
    }

    func testNoElapsedFractionMeansNoMarker() {
        XCTAssertNil(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: nil), in: 50))
    }

    func testMarkerOnAVeryNarrowBarIsCentred() throws {
        let placed = try XCTUnwrap(layout(QuotaBarMetrics(remainingPercent: 50, elapsedFraction: 0.9), in: 2))
        XCTAssertEqual(placed.center, 1)
    }

    // MARK: Nothing drawn for a share that rounds away

    func testAFullBarDrawsNoRedAtAll() throws {
        let full = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 100, elapsedFraction: 0.06).segmentWidths(in: 50))
        XCTAssertEqual(full.used, 0)
        XCTAssertEqual(full.remaining, 50)
    }

    func testABarThatReadsOneHundredPercentDrawsNoRedSliver() throws {
        // 99.6% prints as "100%"; its 0.2pt of red is an anti-aliased smudge.
        let almost = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 99.6, elapsedFraction: nil).segmentWidths(in: 50))
        XCTAssertEqual(almost.used, 0)
        XCTAssertEqual(almost.remaining, 50)
        // On a wide bar the same 0.4% is a visible 0.8pt, but the label still
        // says "100%", so the bar agrees with it.
        let wide = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 99.6, elapsedFraction: nil).segmentWidths(in: 200))
        XCTAssertEqual(wide.used, 0)
    }

    func testAnEmptyBarDrawsNoGreenAtAll() throws {
        let empty = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 0.3, elapsedFraction: nil).segmentWidths(in: 50))
        XCTAssertEqual(empty.used, 50, "reads 0%")
        XCTAssertEqual(empty.remaining, 0)
    }

    func testARealShareIsStillDrawn() throws {
        let two = try XCTUnwrap(QuotaBarMetrics(remainingPercent: 98, elapsedFraction: nil).segmentWidths(in: 50))
        XCTAssertEqual(two.used, 1, accuracy: 1e-9, "2% used of 50pt is a 1pt red segment, and it shows")
    }

    // MARK: Spoken value

    func testSpokenSummaryNamesUsedRemainingAndElapsed() {
        let metrics = QuotaBarMetrics(remainingPercent: 85, elapsedFraction: 0.4)
        XCTAssertEqual(metrics.spokenSummary, "85 percent remaining, 15 percent used, 40 percent of period elapsed")
    }

    func testSpokenSummaryOmitsElapsedWhenThereIsNoMarker() {
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: 85, elapsedFraction: nil).spokenSummary,
                       "85 percent remaining, 15 percent used")
    }

    func testSpokenSummaryForAnUnknownReading() {
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: nil, elapsedFraction: nil).spokenSummary, "no reading")
        XCTAssertEqual(QuotaBarMetrics(remainingPercent: nil, elapsedFraction: 0.25).spokenSummary,
                       "no reading, 25 percent of period elapsed")
    }

    func testSpokenUsedAndRemainingAlwaysAddToOneHundred() {
        for remaining in [0.0, 0.4, 0.5, 14.5, 49.6, 84.6, 99.5, 100.0] {
            let metrics = QuotaBarMetrics(remainingPercent: remaining, elapsedFraction: nil)
            XCTAssertEqual((metrics.remainingPercentRounded ?? -1) + (metrics.usedPercentRounded ?? -1), 100,
                           "remaining \(remaining)")
        }
    }

    // MARK: Period resolution

    func testNumberAndUnitTokensAreReadExactly() {
        XCTAssertEqual(QuotaPeriod.resolve(token: "5h", label: ""), .fixed(5 * 3_600))
        XCTAssertEqual(QuotaPeriod.resolve(token: "168h", label: ""), .fixed(7 * 86_400))
        XCTAssertEqual(QuotaPeriod.resolve(token: "1w", label: "1w window"), .fixed(7 * 86_400))
        XCTAssertEqual(QuotaPeriod.resolve(token: "30d", label: ""), .fixed(30 * 86_400))
    }

    func testTokensTheLooseParserMisreadAreReadExactly() {
        // "31d" contains "1d" and "15h" contains "5h", which the substring rules
        // in `WindowPacing.parseDurationSeconds` take for one day and five hours.
        XCTAssertEqual(QuotaPeriod.resolve(token: "31d", label: "31d window"), .fixed(31 * 86_400))
        XCTAssertEqual(QuotaPeriod.resolve(token: "15h", label: "15h window"), .fixed(15 * 3_600))
    }

    func testTheTokenWinsOverLabelProse() {
        XCTAssertEqual(QuotaPeriod.resolve(token: "5h", label: "Weekly limit"), .fixed(5 * 3_600))
    }

    func testMonthlyAndBillingCycleWindowsAreCalendarMonths() {
        XCTAssertEqual(QuotaPeriod.resolve(token: "billing-cycle", label: "Included plan"), .calendarMonths(1))
        XCTAssertEqual(QuotaPeriod.resolve(token: "monthly", label: ""), .calendarMonths(1))
        XCTAssertEqual(QuotaPeriod.resolve(token: "1mo", label: ""), .calendarMonths(1))
        XCTAssertEqual(QuotaPeriod.resolve(token: "3 months", label: ""), .calendarMonths(3))
        XCTAssertEqual(QuotaPeriod.resolve(token: nil, label: "Monthly limit"), .calendarMonths(1))
        XCTAssertEqual(QuotaPeriod.resolve(token: nil, label: "Billing cycle"), .calendarMonths(1))
    }

    func testNamedCadencesStillResolve() {
        XCTAssertEqual(QuotaPeriod.resolve(token: "weekly", label: ""), .fixed(7 * 86_400))
        XCTAssertEqual(QuotaPeriod.resolve(token: nil, label: "Gemini Models · 5-hour"), .fixed(5 * 3_600))
        XCTAssertEqual(QuotaPeriod.resolve(token: "shared", label: "Third-Party Models · Weekly"), .fixed(7 * 86_400))
        XCTAssertEqual(QuotaPeriod.resolve(token: "daily", label: ""), .fixed(86_400))
    }

    func testAWindowWithNoNamedPeriodHasNone() {
        XCTAssertNil(QuotaPeriod.resolve(token: nil, label: "Unknown"))
        XCTAssertNil(QuotaPeriod.resolve(token: "plan", label: "Included plan"))
        XCTAssertNil(QuotaPeriod.resolve(token: "session", label: "Session"))
        XCTAssertNil(QuotaPeriod.resolve(token: nil, label: "Quota window"))
    }

    // MARK: Month derivation

    func testAMonthlyPeriodStartsOneCalendarMonthBeforeTheReset() throws {
        let month = QuotaPeriod.calendarMonths(1)
        XCTAssertEqual(month.start(endingAt: date("2026-10-15T00:00:00Z"), calendar: calendar), date("2026-09-15T00:00:00Z"))
        XCTAssertEqual(month.start(endingAt: date("2026-12-31T12:00:00Z"), calendar: calendar), date("2026-11-30T12:00:00Z"))
        XCTAssertEqual(month.start(endingAt: date("2026-01-31T00:00:00Z"), calendar: calendar), date("2025-12-31T00:00:00Z"))
    }

    func testAResetOnMarch31StartsOnTheLastDayOfFebruary() {
        let month = QuotaPeriod.calendarMonths(1)
        XCTAssertEqual(month.start(endingAt: date("2026-03-31T00:00:00Z"), calendar: calendar), date("2026-02-28T00:00:00Z"))
        // A leap year keeps the 29th.
        XCTAssertEqual(month.start(endingAt: date("2028-03-31T00:00:00Z"), calendar: calendar), date("2028-02-29T00:00:00Z"))
    }

    func testAResetOnMarch1StartsOnFebruary1() throws {
        let span = try XCTUnwrap(QuotaPeriodSpan.resolve(
            token: "billing-cycle", label: "Included plan", resetAt: date("2026-03-01T00:00:00Z"), calendar: calendar))
        XCTAssertEqual(span.start, date("2026-02-01T00:00:00Z"))
        XCTAssertEqual(span.duration, 28 * 86_400, accuracy: 1)
    }

    func testMonthLengthChangesTheSpanNotJustTheStartDate() throws {
        let long = try XCTUnwrap(QuotaPeriodSpan.resolve(
            token: "monthly", label: "", resetAt: date("2026-08-15T00:00:00Z"), calendar: calendar))
        let short = try XCTUnwrap(QuotaPeriodSpan.resolve(
            token: "monthly", label: "", resetAt: date("2026-03-15T00:00:00Z"), calendar: calendar))
        XCTAssertEqual(long.duration, 31 * 86_400, accuracy: 1)
        XCTAssertEqual(short.duration, 28 * 86_400, accuracy: 1)
    }

    // MARK: Months are counted in UTC, whatever the Mac's time zone is

    /// Runs `body` with the process time zone set to `identifier`, so the default
    /// calendar paths are exercised the way a Mac outside UTC would run them.
    private func withTimeZone<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier)!
        defer { NSTimeZone.default = saved }
        return try body()
    }

    private var chicago: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    func testTheDefaultBillingCalendarIsGregorianUTC() {
        XCTAssertEqual(QuotaPeriod.billingCalendar.identifier, .gregorian)
        XCTAssertEqual(QuotaPeriod.billingCalendar.timeZone.secondsFromGMT(), 0)
    }

    func testAMarch1ResetAtThreeAMUTCStartsOnFebruary1ForAMacInChicago() throws {
        // On a Chicago calendar this reset is Feb 28 at 9pm, so "one month
        // earlier" is Jan 29 and the period is 31 days.  In UTC it is Mar 1 and
        // Feb 1, 28 days.  The default path has to give the UTC answer.
        let reset = date("2026-03-01T03:00:00Z")
        let chicagoStart = try XCTUnwrap(QuotaPeriod.calendarMonths(1).start(endingAt: reset, calendar: chicago))
        XCTAssertEqual(chicagoStart, date("2026-01-29T03:00:00Z"), "guard: a local calendar really does skew this reset")

        try withTimeZone("America/Chicago") {
            let span = try XCTUnwrap(QuotaPeriodSpan.resolve(token: "billing-cycle", label: "Included plan", resetAt: reset))
            XCTAssertEqual(span.start, date("2026-02-01T03:00:00Z"))
            XCTAssertEqual(span.duration, 28 * 86_400, accuracy: 1)

            // Feb 15 at 03:00Z is exactly halfway through a 28-day February.
            let now = date("2026-02-15T03:00:00Z")
            let plan = snapshot(token: "billing-cycle", label: "Included plan", reset: "2026-03-01T03:00:00Z", now: now)
            XCTAssertEqual(try XCTUnwrap(plan.elapsedFraction(now: now)), 0.5, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(QuotaBarMetrics(snapshot: plan, now: now).elapsedFraction), 0.5, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(plan.pacing(now: now)).timeElapsedLabel, "Day 14 of 28")
        }
    }

    func testAMay1ResetAtTwoAMUTCStartsOnApril1ForAMacInChicago() throws {
        let reset = date("2026-05-01T02:00:00Z")
        let chicagoStart = try XCTUnwrap(QuotaPeriod.calendarMonths(1).start(endingAt: reset, calendar: chicago))
        XCTAssertEqual(chicagoStart, date("2026-03-31T02:00:00Z"), "guard: a local calendar really does skew this reset")

        try withTimeZone("America/Chicago") {
            let span = try XCTUnwrap(QuotaPeriodSpan.resolve(token: "monthly", label: "", resetAt: reset))
            XCTAssertEqual(span.start, date("2026-04-01T02:00:00Z"))
            XCTAssertEqual(span.duration, 30 * 86_400, accuracy: 1)
        }
    }

    func testAMarch31ResetFindsFebruary28ForAMacInChicago() throws {
        let reset = date("2026-03-31T04:00:00Z")
        try withTimeZone("America/Chicago") {
            let span = try XCTUnwrap(QuotaPeriodSpan.resolve(token: "billing-cycle", label: "", resetAt: reset))
            XCTAssertEqual(span.start, date("2026-02-28T04:00:00Z"))
            XCTAssertEqual(span.duration, 31 * 86_400, accuracy: 1)
        }
    }

    func testAPeriodAcrossDaylightSavingLastsExactlyWholeDaysForAMacInChicago() throws {
        // Chicago leaves daylight time on Nov 1, 2026, inside this window.  A
        // local calendar would make the month 31 days plus an hour.
        let reset = date("2026-11-15T12:00:00Z")
        try withTimeZone("America/Chicago") {
            let span = try XCTUnwrap(QuotaPeriodSpan.resolve(token: "billing-cycle", label: "", resetAt: reset))
            XCTAssertEqual(span.start, date("2026-10-15T12:00:00Z"))
            XCTAssertEqual(span.duration, 31 * 86_400, accuracy: 1)
        }
    }

    func testTheMarkerIsTheSameInEveryTimeZone() throws {
        let now = date("2026-02-15T03:00:00Z")
        let plan = snapshot(token: "billing-cycle", label: "Included plan", reset: "2026-03-01T03:00:00Z", now: now)
        let fractions = try ["UTC", "America/Chicago", "Asia/Tokyo", "Pacific/Auckland"].map { zone in
            try withTimeZone(zone) { try XCTUnwrap(plan.elapsedFraction(now: now)) }
        }
        for fraction in fractions { XCTAssertEqual(fraction, fractions[0], accuracy: 1e-12) }
    }

    // MARK: Span and elapsed fraction

    func testCursorMonthlyPlanReportsHalfElapsedHalfwayThroughTheCycle() throws {
        // Sep 15 to Oct 15 is 30 days; Sep 30 is exactly 15 of them.
        let now = date("2026-09-30T00:00:00Z")
        let plan = snapshot(token: "billing-cycle", label: "Included plan", remaining: 15,
                            reset: "2026-10-15T00:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(plan.elapsedFraction(now: now, calendar: calendar)), 0.5, accuracy: 1e-9)
        let metrics = QuotaBarMetrics(snapshot: plan, now: now, calendar: calendar)
        XCTAssertEqual(metrics.elapsedPercentRounded, 50)
        XCTAssertEqual(metrics.usedPercentRounded, 85)
    }

    func testAnExplicitPeriodStartWinsOverTheDerivedOne() throws {
        // The derived start would be Sep 15; the provider says the cycle began
        // Sep 20, so Sep 30 is 10 of 25 days in.
        let now = date("2026-09-30T00:00:00Z")
        let plan = snapshot(token: "billing-cycle", label: "Included plan",
                            reset: "2026-10-15T00:00:00Z", periodStart: "2026-09-20T00:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(plan.elapsedFraction(now: now, calendar: calendar)), 10.0 / 25.0, accuracy: 1e-9)
    }

    func testAnImplausibleExplicitStartIsIgnored() throws {
        let now = date("2026-09-30T00:00:00Z")
        // After the reset.
        let after = snapshot(token: "billing-cycle", label: "Included plan",
                             reset: "2026-10-15T00:00:00Z", periodStart: "2026-11-01T00:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(after.elapsedFraction(now: now, calendar: calendar)), 0.5, accuracy: 1e-9)
        // Years before it.
        let ancient = snapshot(token: "billing-cycle", label: "Included plan",
                               reset: "2026-10-15T00:00:00Z", periodStart: "2019-01-01T00:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(ancient.elapsedFraction(now: now, calendar: calendar)), 0.5, accuracy: 1e-9)
    }

    func testAnExplicitStartGivesAMarkerToAWindowWithNoNamedPeriod() throws {
        let now = date("2026-09-30T00:00:00Z")
        let window = snapshot(token: nil, label: "Subscription window",
                              reset: "2026-10-05T00:00:00Z", periodStart: "2026-09-05T00:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(window.elapsedFraction(now: now, calendar: calendar)), 25.0 / 30.0, accuracy: 1e-9)
    }

    func testFixedCadencesReportTheirElapsedFraction() throws {
        let now = date("2026-09-30T12:00:00Z")
        let fiveHour = snapshot(token: "5h", reset: "2026-09-30T14:30:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(fiveHour.elapsedFraction(now: now)), 0.5, accuracy: 1e-9)
        let weekly = snapshot(token: "weekly", reset: "2026-10-03T12:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(weekly.elapsedFraction(now: now)), 4.0 / 7.0, accuracy: 1e-9)
    }

    func testAWindowPastItsResetIsFullyElapsedAndOneNotYetStartedIsNot() throws {
        let now = date("2026-09-30T12:00:00Z")
        let past = snapshot(token: "5h", reset: "2026-09-30T11:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(past.elapsedFraction(now: now)), 1, accuracy: 1e-9)
        let early = snapshot(token: "5h", reset: "2026-09-30T20:00:00Z", now: now)
        XCTAssertEqual(try XCTUnwrap(early.elapsedFraction(now: now)), 0, accuracy: 1e-9)
    }

    func testNoResetMeansNoMarker() {
        let now = date("2026-09-30T12:00:00Z")
        XCTAssertNil(snapshot(token: "5h", reset: nil, now: now).elapsedFraction(now: now))
        XCTAssertNil(snapshot(token: "billing-cycle", label: "Included plan", reset: nil, now: now).periodSpan())
    }

    func testNoDerivablePeriodMeansNoMarker() {
        let now = date("2026-09-30T12:00:00Z")
        let plan = snapshot(token: "plan", label: "Included plan", reset: "2026-10-15T00:00:00Z", now: now)
        XCTAssertNil(plan.elapsedFraction(now: now))
        XCTAssertNil(QuotaBarMetrics(snapshot: plan, now: now).elapsedFraction)
    }

    func testAnAbsurdlyLongPeriodIsNotDrawn() {
        let now = date("2026-09-30T12:00:00Z")
        let window = snapshot(token: "9000d", reset: "2026-10-15T00:00:00Z", now: now)
        XCTAssertNil(window.elapsedFraction(now: now))
    }

    // MARK: Pacing follows the same span

    func testPacingAgreesWithTheMarkerForAMonthlyWindow() throws {
        let now = date("2026-09-30T00:00:00Z")
        let plan = snapshot(token: "billing-cycle", label: "Included plan", remaining: 15,
                            reset: "2026-10-15T00:00:00Z", now: now)
        let pacing = try XCTUnwrap(plan.pacing(now: now, calendar: calendar))
        XCTAssertEqual(pacing.timeElapsedPercent, 50, accuracy: 1e-9)
        XCTAssertEqual(pacing.durationSeconds, 30 * 86_400, accuracy: 1)
        XCTAssertEqual(pacing.timeElapsedLabel, "Day 15 of 30")
        XCTAssertFalse(pacing.isUnderCapPace)
    }
}
