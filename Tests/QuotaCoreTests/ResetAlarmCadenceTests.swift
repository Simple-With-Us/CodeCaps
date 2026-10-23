import XCTest
@testable import QuotaCore

/// The iOS companion has only a wire window's token and label to go on, and the
/// reset alarm's "largest window" rule depends on getting the period right.
final class ResetAlarmCadenceTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    func testDurationTokensAreReadInEveryUnit() {
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "5h", label: ""), 5 * hour)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "168h", label: ""), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "300m", label: ""), 5 * hour)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "1w", label: ""), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "31d", label: ""), 31 * day)
    }

    func testNamedCadencesFallBackToTheLabel() {
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "5-hour window"), 5 * hour)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "weekly", label: "Weekly window"), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "7-day window"), 7 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "Daily window"), day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "billing-cycle", label: "Included plan"), 30 * day)
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: "session", label: ""), 5 * hour)
    }

    func testAMonthlyHintMakesACadenceLessPlanAMonth() {
        XCTAssertNil(ResetAlarmCadence.periodSeconds(token: nil, label: "Included plan"))
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: nil, label: "Included plan", monthlyHint: true), 30 * day)
    }

    func testAnUnreadableCadenceIsUnknownNotGuessed() {
        XCTAssertNil(ResetAlarmCadence.periodSeconds(token: nil, label: "Opus quota"))
        XCTAssertNil(ResetAlarmCadence.periodSeconds(token: "abc", label: ""))
        XCTAssertNil(ResetAlarmCadence.durationSeconds("0h"))
    }

    func testCaptionsMatchWhatTheOwnerReadsInGlance() {
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 5 * hour), "5h")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 7 * day), "7d")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 30 * day), "1m")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 31 * day), "1m")
        XCTAssertEqual(ResetAlarmCadence.caption(forPeriod: 90 * 60), "90m")
    }

    // MARK: - The one period resolver

    /// Owner 2026-10-22: the Muse Code five hour marker sat at 91%, and the
    /// caption beside it and the marker were two different resolvers.  A label
    /// that named both a five hour window and a day took a "5h" caption beside
    /// a marker drawn for a whole day, which puts the marker in the wrong place.
    ///
    /// The resolver is the one every surface asks now, so these tests pin what
    /// it says about the windows the owner actually sees.
    func testTheResolverReadsTheHourFormsIncludingTheThreeHourOne() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "3h", label: "3h window"), .fixed(3 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "3-hour window"), .fixed(3 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "3h window"), .fixed(3 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "5-hour window"), .fixed(5 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "4-hour window"), .fixed(4 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "1-hour window"), .fixed(hour))
    }

    /// A window that names a five hour window beside a day is a five hour
    /// window, and the caption and the marker have to say so together.
    func testTheHourFormWinsOverTheDayAndWeekWords() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "shared", label: "5-hour daily limit"), .fixed(5 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "shared", label: "5-hour weekly limit"), .fixed(5 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "shared", label: "5-hour monthly limit"), .fixed(5 * hour))
    }

    /// The token is the reader's own statement of the period, so it wins.
    func testTheTokenWinsOverTheLabel() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "5h", label: "Weekly limit"), .fixed(5 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "7d", label: "5-hour window"), .fixed(7 * day))
    }

    /// The words are read whole, so "24h" is a day and never the four hours
    /// inside it, and "12-hour" is twelve hours and never the two inside it.
    func testTheWordsAreReadWhole() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "24h", label: ""), .fixed(day))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "24-hour window"), .fixed(day))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "12-hour window"), .fixed(12 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "15h window"), .fixed(15 * hour))
    }

    /// A month is a calendar month, not thirty days, so the marker on a monthly
    /// bar is drawn for the month the provider means.
    func testAMonthIsACalendarMonth() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "monthly", label: ""), .calendarMonths(1))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "Monthly limit"), .calendarMonths(1))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: nil, label: "Billing cycle"), .calendarMonths(1))
    }

    /// MiniMax has no four hour window:  its coding plan is five hours.
    func testMiniMaxsFourHourWindowIsFiveHours() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "4h", label: "4h window",
                                                 providerKey: "minimax"), .fixed(5 * hour))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "4h", label: "4h window"), .fixed(4 * hour))
    }

    /// Cursor's included plan resets with its monthly billing cycle and carries
    /// no cadence of its own.
    func testCursorsIncludedPlanIsAMonth() {
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "weekly", label: "Included plan",
                                                 providerKey: "cursor"), .calendarMonths(1))
        XCTAssertEqual(ResetAlarmCadence.resolve(token: "weekly", label: "Included plan"), .fixed(7 * day))
    }

    /// A monthly period starts one calendar month before the reset, so a reset
    /// on Mar 31 starts on Feb 28.
    func testACalendarMonthStartsOnTheCalendar() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 31
        components.hour = 12
        let calendar = ResetAlarmCadence.billingCalendar
        let end = calendar.date(from: components)!
        let start = ResetAlarmCadence.start(of: .calendarMonths(1), endingAt: end)!
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 2)
        XCTAssertEqual(parts.day, 28)
    }
}
