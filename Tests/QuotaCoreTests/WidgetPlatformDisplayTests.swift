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

    /// The companion passes the producer's own window token, as the Mac does.
    /// A window that carried a token is a normal window even when its label
    /// says nothing, and only a window that carried none may be read as the
    /// extra meter from its label.  Presence is the signal, not meaning.
    func testACadenceTokenKeepsANormalWindowFromBeingTheExtraMeter() {
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: "7d", label: "Usage", resetAt: nil))
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: "5h", label: "Usage", resetAt: nil))
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: nil, label: "Usage", resetAt: nil))
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: "7d", label: "Extra balance", resetAt: nil))
        // Presence is the signal, not meaning: a token the vocabulary cannot
        // read still keeps an unlabelled window from being the extra meter.
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: "foo", label: "Usage", resetAt: nil))
    }

    /// The rules the companion's source-text tests used to pin by string, now
    /// pinned by behavior: a masked window and a non-finite reading never speak
    /// for the card, and a card with nothing believable has no headline.
    func testHeadlineLeavesMaskedAndNonFiniteReadingsOut() {
        XCTAssertEqual(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: true, remainingPercent: 5),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 40)
        ]), 40)
        XCTAssertEqual(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: .nan),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 40)
        ]), 40)
        XCTAssertNil(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: .infinity),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: true, remainingPercent: 5)
        ]))
        XCTAssertEqual(CardHeadline.percent([
            CardHeadline.Reading(isMuseAssistExtra: true, isMasked: false, remainingPercent: .nan),
            CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 0)
        ]), 0)
    }

    /// An empty window token is a token the producer sent, and the Mac keeps it
    /// that way: `QuotaWindow` decodes `""` as `""`, and the vocabulary reads
    /// only nil as tokenless.  The companion stores the wire token unchanged so
    /// the two surfaces classify the same payload the same way.
    func testAnEmptyWindowTokenIsKeptAsATokenOnTheMac() throws {
        let json = #"{"id":"w","provider":"Muse Assist","providerKey":"muse-assist","label":"Usage","window":""}"#
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.window, "")
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: decoded.window, label: "Usage", resetAt: nil))
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist", windowToken: nil, label: "Usage", resetAt: nil))
    }
}
