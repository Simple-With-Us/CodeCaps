import XCTest
@testable import CodeCaps

/// Pins the fleet band stamp.  A source that last reported today shows its time
/// alone; anything older shows the date as well, because a bare time beside a
/// clock reading earlier in the day reads as a reading that has not happened
/// yet rather than yesterday's (owner report 2026-10-18).
///
/// The expectations below are written in US English on purpose, so the test pins
/// the locale and calendar it hands the formatter rather than inheriting the
/// runner's.  Otherwise the same assertions pass on Jay's Mac and fail in CI on
/// anything that abbreviates the month differently, renders a 24-hour clock, or
/// defaults to a non-Gregorian calendar.
final class GlanceReportedStampTests: XCTestCase {
    private let locale = Locale(identifier: "en_US_POSIX")

    /// Gregorian, in a fixed zone, so the fixtures below mean the instant they
    /// are written to mean regardless of where the suite runs.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return calendar
    }()

    /// 2026-10-18 14:00 local, so the same-day and previous-day cases cannot
    /// drift across a midnight as the suite runs.
    private lazy var now: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 14, minute: 0))!
    }()

    private func stamp(_ observedAt: Date, now: Date) -> String {
        glanceReportedStamp(observedAt, now: now, locale: locale, calendar: calendar)
    }

    func testTodayShowsTimeOnly() {
        let stamp = self.stamp(calendar.date(byAdding: .hour, value: -1, to: now)!, now: now)
        XCTAssertFalse(stamp.contains(","))
        XCTAssertFalse(stamp.lowercased().contains("oct"))
    }

    func testAClockEarlierThanTheStampMarksItAsYesterday() {
        // 4:49 AM against a 3:40 AM clock: yesterday's reading, and the exact
        // case the owner reported.
        let observed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 4, minute: 49))!
        let clock = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 3, minute: 40))!
        let stamp = self.stamp(observed, now: clock)
        XCTAssertTrue(stamp.contains("Oct 17"), "yesterday's stamp must carry its date, got \(stamp)")
        XCTAssertTrue(stamp.contains("4:49"), "the time must survive alongside the date, got \(stamp)")
    }

    func testPreviousDayCarriesMonthAndDay() {
        let observed = calendar.date(byAdding: .day, value: -1, to: now)!
        let stamp = self.stamp(observed, now: now)
        XCTAssertTrue(stamp.contains("Oct 17"), "got \(stamp)")
        XCTAssertFalse(stamp.contains("2026"), "the current year is noise on the band, got \(stamp)")
    }

    func testDifferentYearCarriesTheYear() {
        let observed = calendar.date(byAdding: .year, value: -1, to: now)!
        let stamp = self.stamp(observed, now: now)
        XCTAssertTrue(stamp.contains("2025"), "a stamp from another year must say which, got \(stamp)")
    }

    func testJustBeforeAndJustAfterMidnightDiffer() {
        let endOfDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23, minute: 59))!
        let startOfDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 1))!
        let late = self.stamp(endOfDay, now: now)
        let early = self.stamp(startOfDay, now: now)
        XCTAssertTrue(late.contains("Oct 17"), "got \(late)")
        XCTAssertFalse(early.contains("Oct"), "same-day reading stays time-only, got \(early)")
    }

    /// The regression Sentry raised: a reader whose locale is not US English
    /// still gets the date on the band, it is just spelled their way.  This is
    /// the behaviour the assertions above can no longer see, because they pin a
    /// locale on purpose.
    func testStampFollowsTheGivenLocaleRatherThanTheRunners() {
        let observed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 16, minute: 49))!
        let german = stamp(observed, now: now, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(german.contains(","), "the date must still ride along, got \(german)")
        XCTAssertFalse(german.contains("Oct"), "a German reader must not be shown an English month, got \(german)")
        XCTAssertNotEqual(german, stamp(observed, now: now), "the two locales must actually differ here")
    }

    private func stamp(_ observedAt: Date, now: Date, locale: Locale) -> String {
        glanceReportedStamp(observedAt, now: now, locale: locale, calendar: calendar)
    }
}