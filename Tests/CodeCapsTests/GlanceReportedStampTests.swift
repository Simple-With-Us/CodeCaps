import XCTest
@testable import CodeCaps

/// Pins the fleet band stamp.  A source that last reported today shows its time
/// alone; anything older shows the date as well, because a bare time beside a
/// clock reading earlier in the day reads as a reading that has not happened
/// yet rather than yesterday's (owner report 2026-10-18).
final class GlanceReportedStampTests: XCTestCase {
    private let calendar = Calendar.current

    /// 2026-10-18 14:00 local, so the same-day and previous-day cases cannot
    /// drift across a midnight as the suite runs.
    private lazy var now: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 14, minute: 0))!
    }()

    func testTodayShowsTimeOnly() {
        let stamp = glanceReportedStamp(calendar.date(byAdding: .hour, value: -1, to: now)!, now: now)
        XCTAssertFalse(stamp.contains(","))
        XCTAssertFalse(stamp.lowercased().contains("oct"))
    }

    func testAClockEarlierThanTheStampMarksItAsYesterday() {
        // 4:49 AM against a 3:40 AM clock: yesterday's reading, and the exact
        // case the owner reported.
        let observed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 4, minute: 49))!
        let clock = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 3, minute: 40))!
        let stamp = glanceReportedStamp(observed, now: clock)
        XCTAssertTrue(stamp.contains("Oct 17"), "yesterday's stamp must carry its date, got \(stamp)")
        XCTAssertTrue(stamp.contains("4:49"), "the time must survive alongside the date, got \(stamp)")
    }

    func testPreviousDayCarriesMonthAndDay() {
        let observed = calendar.date(byAdding: .day, value: -1, to: now)!
        let stamp = glanceReportedStamp(observed, now: now)
        XCTAssertTrue(stamp.contains("Oct 17"), "got \(stamp)")
        XCTAssertFalse(stamp.contains("2026"), "the current year is noise on the band, got \(stamp)")
    }

    func testDifferentYearCarriesTheYear() {
        let observed = calendar.date(byAdding: .year, value: -1, to: now)!
        let stamp = glanceReportedStamp(observed, now: now)
        XCTAssertTrue(stamp.contains("2025"), "a stamp from another year must say which, got \(stamp)")
    }

    func testJustBeforeAndJustAfterMidnightDiffer() {
        let endOfDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 23, minute: 59))!
        let startOfDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 1))!
        let late = glanceReportedStamp(endOfDay, now: now)
        let early = glanceReportedStamp(startOfDay, now: now)
        XCTAssertTrue(late.contains("Oct 17"), "got \(late)")
        XCTAssertFalse(early.contains("Oct"), "same-day reading stays time-only, got \(early)")
    }
}