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
    func testBarQualifierConstantsAreShortNounsNotCadenceForms() {
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierWeekly, "weekly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierMonthly, "monthly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierDaily, "daily")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierHourly, "hourly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierAdditional, "additional")

        for constant in [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierMonthly,
            QuotaWindowVocabulary.barQualifierDaily,
            QuotaWindowVocabulary.barQualifierHourly,
            QuotaWindowVocabulary.barQualifierAdditional
        ] {
            for forbiddenHyphenated in [
                QuotaWindowVocabulary.sevenDay,
                QuotaWindowVocabulary.fiveHour,
                QuotaWindowVocabulary.oneMonth,
                QuotaWindowVocabulary.otherLimit
            ] {
                XCTAssertNotEqual(constant, forbiddenHyphenated,
                    "qualifier '\(constant)' must not repeat the cadence form '\(forbiddenHyphenated)'.")
            }
        }
    }
}
