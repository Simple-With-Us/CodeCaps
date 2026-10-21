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

    // MARK: - The line a capped plan says

    /// The cap line is shared by the Mac's menu-bar window, its PiP and the
    /// phone companion, so one plan reads the same on every surface.
    func testAtCapSummaryNamesTheCapAndCountsDownToItsReset() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let reset = now.addingTimeInterval(37 * 3_600 + 30 * 60)
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "7-day", resetAt: reset, now: now),
                       "7-day cap resets in 1d 13h")
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "5-hour", resetAt: now.addingTimeInterval(3_600), now: now),
                       "5-hour cap resets in 1h")
    }

    /// A cap with no clock still says so, and a reset that has already passed
    /// does not become "resets in due".
    func testAtCapSummaryWithoutAUsableCountdownJustNamesTheCap() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "7-day", resetAt: nil, now: now),
                       "7-day cap")
        XCTAssertEqual(QuotaWindowVocabulary.atCapSummary(cadence: "7-day", resetAt: now.addingTimeInterval(-60), now: now),
                       "7-day cap")
    }

    /// The countdown skips a unit that is zero, so it never reads "1d 0h".
    func testResetCountdownSkipsZeroUnits() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(86_400), now: now), "1d")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(2 * 3_600 + 42 * 60), now: now), "2h 42m")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(QuotaWindowVocabulary.resetCountdown(nil, now: now), "")
    }

    /// A window that already carries the canonical cadence keeps it; anything
    /// else is re-derived, so an at-cap line never says "Other limit" when the
    /// window meant something narrower.
    func testAtCapCadenceKeepsTheCanonicalName() {
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "7-day"), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "5-hour"), "5-hour")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "weekly"), "7-day")
    }
}
