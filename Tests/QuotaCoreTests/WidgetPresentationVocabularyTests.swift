import XCTest
@testable import QuotaCore

/// WidgetPresentation lives in the iOS target; these tests pin the shared
/// vocabulary helpers the widget parser calls through QuotaWindowVocabulary.
final class WidgetPresentationVocabularyTests: XCTestCase {
    func testFormatCadenceUsesHyphenatedLabels() {
        XCTAssertEqual(
            QuotaWindowVocabulary.standardCadence(windowToken: "7d", label: "weekly cap"),
            "7-day"
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.standardCadence(windowToken: "1m", label: "billing"),
            "1-month"
        )
    }

    func testPopoverCaptionMatchesMenuBarUnits() {
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: "7d", label: "7-day window"),
            "7d"
        )
    }

    /// Owner 2026-10-21 saw "7d 7-day" duplicate in the Mac widget caption row
    /// for the Antigravity weekly allowance.  The cadence token sits on the
    /// same line as the qualifier, so the qualifier must NEVER repeat the
    /// cadence form ("7-day" / "5-hour" / "1-month").  Short nouns ("weekly",
    /// "monthly", "additional") are the only forms the caption supports.
    ///
    /// Kody review 2026-10-21: the forbidden list named "7-day", "5-hour",
    /// "1-month" and "Other limit" but left the daily cadence and the compact
    /// tokens ("1d", "7d", "5h", "1m", "+") unguarded, so the stated invariant
    /// was not actually enforced.  The list below is the shared one the
    /// vocabulary ships.
    func testBarQualifierConstantsAreShortNounsNotCadenceForms() {
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierWeekly, "weekly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierMonthly, "monthly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierDaily, "daily allowance")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierHourly, "hourly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierAdditional, "additional")

        for constant in [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierMonthly,
            QuotaWindowVocabulary.barQualifierDaily,
            QuotaWindowVocabulary.barQualifierHourly,
            QuotaWindowVocabulary.barQualifierAdditional
        ] {
            for forbiddenCadenceForm in QuotaWindowVocabulary.barQualifierForbiddenCadenceForms {
                XCTAssertNotEqual(constant, forbiddenCadenceForm,
                    "qualifier '\(constant)' must not repeat the cadence form '\(forbiddenCadenceForm)'.")
            }
        }

        XCTAssertTrue(QuotaWindowVocabulary.barQualifierForbiddenCadenceForms.contains(QuotaWindowVocabulary.oneDay),
            "the daily cadence form must stay on the forbidden list.")
        for compactToken in ["5h", "1d", "7d", "1m", "+"] {
            XCTAssertTrue(QuotaWindowVocabulary.barQualifierForbiddenCadenceForms.contains(compactToken),
                "the compact cadence token '\(compactToken)' must stay on the forbidden list.")
        }
    }

    /// Kody review 2026-10-21: the daily qualifier restated the cadence the
    /// caption token already showed, so a daily window read "1d daily".  The
    /// qualifier names the kind of allowance instead.
    func testDailyQualifierDoesNotRestateTheCadenceToken() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(forLabel: "Daily cap", sharesCadence: true),
            "daily allowance"
        )
        XCTAssertNotEqual(
            QuotaWindowVocabulary.barQualifier(forLabel: "Daily cap", sharesCadence: true),
            "daily"
        )

        let token = QuotaWindowVocabulary.popoverCaption(windowToken: "Daily", label: "Daily cap")
        XCTAssertEqual(token, "1d")
        let caption = "\(token) \(QuotaWindowVocabulary.barQualifier(forLabel: "Daily cap", sharesCadence: true))"
        XCTAssertEqual(caption, "1d daily allowance")
        XCTAssertNotEqual(caption, "1d daily")
    }

    /// Kody rule "Avoid Substring Matching for Canonical Limit/Window Labels"
    /// (binding, 2026-10-21): a canonical qualifier is matched on an exact
    /// lexical token, never as a substring, so "nothourly" is not an hourly
    /// window.
    func testBarQualifierMatchesExactTokensNotSubstrings() {
        XCTAssertEqual(QuotaWindowVocabulary.barQualifier(forLabel: "nothourly"), "")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifier(forLabel: "notweekly"), "")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifier(forLabel: "notmonthly"), "")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifier(forLabel: "notdaily"), "")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifier(forLabel: "unhourlyplan"), "")

        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(forLabel: "Hourly plan"),
            QuotaWindowVocabulary.barQualifierHourly
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(forLabel: "Weekly cap"),
            QuotaWindowVocabulary.barQualifierWeekly
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(forLabel: "Monthly plan"),
            QuotaWindowVocabulary.barQualifierMonthly
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(forLabel: "Daily cap"),
            QuotaWindowVocabulary.barQualifierDaily
        )
    }

    /// Kody review 2026-10-21: a lone bar printing a cadence word says the
    /// same thing twice, so the qualifier is only printed when a sibling bar
    /// shares the cadence.
    func testLoneCadenceBarPrintsNoQualifierAndSharedCadenceDoes() {
        let lone = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "Weekly", label: "Weekly cap")
        ])
        XCTAssertEqual(lone, [""])

        // The Antigravity weekly bar sits beside a 5-hour bar, a different
        // cadence, so neither bar needs a qualifier.
        let mixedCadences = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "5h", label: "5-hour window"),
            QuotaWindowVocabulary.BarCaption(cadence: "Weekly", label: "Weekly cap")
        ])
        XCTAssertEqual(mixedCadences, ["", ""])

        // Two 7-day bars share one cadence, so they read "weekly" and
        // "additional" (owner-approved, 2026-10-21).
        let sharedCadence = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "7d", label: "Free weekly limit"),
            QuotaWindowVocabulary.BarCaption(cadence: "7d", label: "Additional allowance")
        ])
        XCTAssertEqual(sharedCadence, [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierAdditional
        ])

        // Two daily bars share one cadence and read the allowance word.
        let sharedDaily = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "Daily", label: "Daily cap"),
            QuotaWindowVocabulary.BarCaption(cadence: "Daily", label: "Daily allowance cap")
        ])
        XCTAssertEqual(sharedDaily, [
            QuotaWindowVocabulary.barQualifierDaily,
            QuotaWindowVocabulary.barQualifierDaily
        ])
    }

    /// The cadence group is what decides whether two bars share a cadence, so
    /// it has to follow the period rather than the wording.
    func testBarCadenceGroupFollowsThePeriod() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Weekly", label: "Weekly cap"),
            QuotaWindowVocabulary.sevenDay
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "5h", label: "5-hour window"),
            QuotaWindowVocabulary.fiveHour
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Daily", label: "Daily cap"),
            QuotaWindowVocabulary.oneDay
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "1m", label: "Billing cycle"),
            QuotaWindowVocabulary.oneMonth
        )
    }
}
