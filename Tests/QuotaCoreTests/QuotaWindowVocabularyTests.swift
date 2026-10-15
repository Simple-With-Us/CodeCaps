import XCTest
@testable import QuotaCore

final class QuotaWindowVocabularyTests: XCTestCase {
    func testStandardCadenceFromTokens() {
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "5h", label: ""), "5-hour")
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "7d", label: ""), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.standardCadence(windowToken: "1m", label: ""), "1-month")
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
