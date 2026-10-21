import XCTest
@testable import QuotaCore

final class QuotaWindowVocabularyTests: XCTestCase {
    func testStandardCadenceFromTokens() {
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "5h", label: ""), "5-hour")
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "7d", label: ""), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "1m", label: ""), "1-month")
    }

    /// An extra allowance names no period of its own.
    ///
    /// It joins the group of the one sibling that has a period,  and the sibling
    /// resolution is what does that.  The group lookup itself must not hand it a
    /// period,  or a bar that prints "7d" would be split from the sibling that
    /// prints the same token (Kody review 2026-10-21).
    func testAnExtraAllowanceHasNoGroupOfItsOwn() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(
                cadence: "Other limit",
                label: "Other limit",
                isExtraAllowance: true
            ),
            QuotaWindowVocabulary.otherLimit
        )
    }

    /// A canonical label names its period.
    ///
    /// The widget renders "7-day window",  "5-hour window" and "1-month window",
    /// and a bar whose label says one of them has to group with the bar that
    /// prints the same token,  or the two are split (Kody review 2026-10-21).
    func testACanonicalLabelNamesItsPeriod() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "7-day window"),
            QuotaWindowVocabulary.sevenDay
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "5-hour window"),
            QuotaWindowVocabulary.fiveHour
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "1-month window"),
            QuotaWindowVocabulary.oneMonth
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Other limit", label: "1-day window"),
            QuotaWindowVocabulary.oneDay
        )
    }

    func testOpaqueAnthropicKeyMapsToOtherLimit() {
        let label = QuotaWindowVocabulary.windowLabel(windowToken: nil, existingLabel: "iguana_necktie", resetAt: nil, periodStart: nil)
        XCTAssertEqual(label, "Other limit window")
    }

    func testOpaqueKeyWithMonthlySpanMapsToOneMonth() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(30 * 86_400)
        let cadence = QuotaWindowVocabulary.standardCadence(
            windowToken: nil,
            label: "iguana_necktie",
            resetAt: end,
            periodStart: start
        )
        XCTAssertEqual(cadence, "1-month")
    }

    func testStripsModelParentheticalOnSanitize() {
        let window = QuotaWindow(
            id: "x",
            provider: "Claude",
            label: "5h window (Opus)",
            remainingPercent: 50,
            window: "5h",
            occurredAt: "2026-01-01T00:00:00Z"
        ).normalizedForExport()
        XCTAssertFalse(window.label.lowercased().contains("opus"))
        XCTAssertTrue(window.label.contains("5-hour"))
    }

    func testAntigravityPoolKeepsHead() {
        let label = QuotaWindowVocabulary.windowLabel(
            windowToken: "7d",
            existingLabel: "Gemini · Weekly",
            resetAt: nil,
            periodStart: nil
        )
        XCTAssertEqual(label, "Gemini · 7-day")
    }

    func testPopoverCaptionCompactUnits() {
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: "5h", label: "5-hour window"),
            "5h"
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: "7d", label: "7-day window"),
            "7d"
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: nil, label: "Additional tokens", isExtraAllowance: true),
            "+"
        )
    }

    func testExtraAllowanceLabelDetection() {
        XCTAssertTrue(QuotaWindowVocabulary.isExtraAllowanceLabel("Additional additional tokens"))
        XCTAssertTrue(QuotaWindowVocabulary.isExtraAllowanceLabel("plan + extra"))
    }

    func testMuseAssistWeeklyAndExtraMetersAreClassifiedSeparately() {
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistWeekly(
            providerKey: "muse-assist",
            windowToken: "168h",
            label: "Free weekly limit"
        ))
        XCTAssertTrue(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist",
            windowToken: nil,
            label: "Additional tokens"
        ))
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistExtra(
            providerKey: "muse-assist",
            windowToken: "8h",
            label: "8h window"
        ))
        XCTAssertFalse(QuotaWindowVocabulary.isMuseAssistWeekly(
            providerKey: "openai",
            windowToken: "168h",
            label: "Weekly"
        ))
    }
}
