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
}
