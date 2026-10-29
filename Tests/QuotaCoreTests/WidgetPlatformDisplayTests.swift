import XCTest
@testable import QuotaCore

final class WidgetPlatformDisplayTests: XCTestCase {
    func testCursorNeverRendersAsLowercaseSlug() {
        let title = WidgetPlatformDisplay.title(
            canonicalKey: "cursor",
            manifestProviderLabel: "cursor",
            wireProvider: "cursor"
        )
        XCTAssertEqual(title, "Cursor")
        XCTAssertFalse(WidgetPlatformDisplay.isRawProviderSlug(title, canonicalKey: "cursor"))
    }

    func testNoCanonicalPlatformTitleIsRawLowercaseProviderId() {
        let slugs = [
            "cursor", "anthropic", "openai", "minimax", "xai", "grok-bot",
            "muse-assist", "muse-code", "google-antigravity", "kimi",
        ]
        for slug in slugs {
            let title = WidgetPlatformDisplay.title(
                canonicalKey: slug,
                manifestProviderLabel: slug,
                wireProvider: slug
            )
            XCTAssertFalse(
                WidgetPlatformDisplay.isRawProviderSlug(title, canonicalKey: slug),
                "widget row for \(slug) must not render the raw id \"\(title)\""
            )
        }
    }

    func testMuseAssistUsableExtraSpeaksForTheCardHeadline() {
        let readings = [
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 0),
            CardHeadline.Reading(isMuseAssistExtra: true, isMasked: false, remainingPercent: 82)
        ]
        XCTAssertEqual(CardHeadline.percent(readings), 82)
    }

    func testSpentExtraAndMaskedReadingsDoNotSpeakForTheHeadline() {
        XCTAssertEqual(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 0),
            CardHeadline.Reading(isMuseAssistExtra: true, isMasked: false, remainingPercent: 0)
        ]), 0)
        XCTAssertEqual(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 40),
            CardHeadline.Reading(isMuseAssistExtra: true, isMasked: true, remainingPercent: 82)
        ]), 40)
        XCTAssertNil(CardHeadline.percent([]))
    }

    func testOtherProvidersKeepTheLowestReading() {
        XCTAssertEqual(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 90),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 19)
        ]), 19)
    }

    func testUpdatedStampNamesTheDayWhenItIsNotToday() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertEqual(UpdatedStamp.label(now, now: now), now.formatted(date: .omitted, time: .shortened))
        XCTAssertNotEqual(UpdatedStamp.label(yesterday, now: now),
                          yesterday.formatted(date: .omitted, time: .shortened))
    }
}
